import AppKit
import Foundation

struct ChatGPTTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String
    let expiresIn: TimeInterval
    let scope: String?
    let earliestRefresh: Date?

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try fields.decode(String.self, forKey: .accessToken)
        refreshToken = try fields.decodeIfPresent(String.self, forKey: .refreshToken)
        idToken = try fields.decodeIfPresent(String.self, forKey: .idToken)
        tokenType = try fields.decode(String.self, forKey: .tokenType)
        expiresIn = try fields.decode(TimeInterval.self, forKey: .expiresIn)
        scope = try fields.decodeIfPresent(String.self, forKey: .scope)
        if let seconds = try? fields.decode(Double.self, forKey: .earliestRefresh), seconds.isFinite, seconds > 0 {
            earliestRefresh = Date(timeIntervalSince1970: seconds)
        } else if let value = try? fields.decode(String.self, forKey: .earliestRefresh) {
            let format = Date.ISO8601FormatStyle()
            earliestRefresh = (try? format.parse(value))
                ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
        } else {
            earliestRefresh = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
        case earliestRefresh = "earliest_refresh_at"
    }
}

struct ChatGPTAuthorization: Sendable {
    let clientID: String
    let identity: ChatGPTIdentity
    let tokens: ChatGPTTokenResponse
}

protocol ChatGPTTokenLifecycle: Sendable {
    func refresh(clientID: String, refreshToken: String) async throws -> ChatGPTTokenResponse
    func revoke(clientID: String, refreshToken: String) async throws
}

struct ChatGPTOAuth: ChatGPTTokenLifecycle {
    let http: ChatGPTHTTP

    @MainActor
    func signIn(clientID: String?, hostID: String, requestConsent: Bool) async throws -> ChatGPTAuthorization {
        var requested = clientID ?? ChatGPTEndpoints.dynamicClient
        for attemptIndex in 0..<2 {
            let attempt = try ChatGPTAuthorizationAttempt()
            let (callback, redirectURI) = try await authorize(
                attempt, clientID: requested, hostID: hostID, requestConsent: requestConsent && attemptIndex == 0
            )
            requested = try callback.issuedClientID(for: requested)
            let response: ChatGPTTokenResponse
            do {
                response = try await exchange(callback.code, clientID: requested, redirectURI: redirectURI, verifier: attempt.verifier)
            } catch let failure as ChatGPTFailure where failure.code == "invalid_grant" && attemptIndex == 0 {
                // A consumed or expired code needs a fresh browser authorization with this issued client.
                continue
            }
            guard let idToken = response.idToken, !idToken.isEmpty else { throw ChatGPTFailure(kind: .invalidIdentity) }
            let keys = try await http.json(ChatGPTIDToken.KeySet.self, for: URLRequest(url: ChatGPTEndpoints.jwks),
                                           secrets: [idToken, response.accessToken, response.refreshToken ?? ""])
            let identity = try ChatGPTIDToken.verify(idToken, keys: keys, clientID: requested, nonce: attempt.nonce)
            return ChatGPTAuthorization(clientID: requested, identity: identity, tokens: response)
        }
        throw ChatGPTFailure(kind: .credential)
    }

    @MainActor
    private func authorize(
        _ attempt: ChatGPTAuthorizationAttempt, clientID: String, hostID: String, requestConsent: Bool
    ) async throws -> (ChatGPTCallback, String) {
        let loopback = try ChatGPTLoopback(state: attempt.state)
        loopback.start()
        defer { loopback.stop() }

        var redirectURI: String?
        for try await event in loopback.events {
            try Task.checkCancellation()
            switch event {
            case .ready(let port):
                let redirect = "http://127.0.0.1:\(port)" + ChatGPTCallback.path
                redirectURI = redirect
                let url = try attempt.url(clientID: clientID, hostID: hostID, redirectURI: redirect, requestConsent: requestConsent)
                guard NSWorkspace.shared.open(url) else { throw ChatGPTFailure(kind: .browser) }
            case .callback(let callback):
                guard let redirectURI else { throw ChatGPTFailure(kind: .loopback) }
                return (callback, redirectURI)
            }
        }
        try Task.checkCancellation()
        throw ChatGPTFailure(kind: .loopback)
    }

    func exchange(_ code: String, clientID: String, redirectURI: String, verifier: String) async throws -> ChatGPTTokenResponse {
        let form = ChatGPTHTTP.form(ChatGPTEndpoints.token, [
            ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
            ("code_verifier", verifier), ("redirect_uri", redirectURI), ("resource", ChatGPTEndpoints.resource),
        ])
        return try await http.json(ChatGPTTokenResponse.self, for: form, secrets: [code, verifier])
    }

    func refresh(clientID: String, refreshToken: String) async throws -> ChatGPTTokenResponse {
        let form = ChatGPTHTTP.form(ChatGPTEndpoints.token, [
            ("grant_type", "refresh_token"), ("client_id", clientID),
            ("refresh_token", refreshToken), ("resource", ChatGPTEndpoints.resource),
        ])
        return try await http.json(ChatGPTTokenResponse.self, for: form, secrets: [refreshToken], stage: .refresh)
    }

    func revoke(clientID: String, refreshToken: String) async throws {
        for retry in 0..<3 {
            do {
                var discovery = URLRequest(url: ChatGPTEndpoints.discovery)
                discovery.timeoutInterval = 6
                let server = try await http.json(Discovery.self, for: discovery)
                guard server.issuer == ChatGPTEndpoints.issuer,
                      let url = URLComponents(url: server.revocationEndpoint, resolvingAgainstBaseURL: false),
                      url.scheme == "https", url.host == "auth.openai.com", url.port == nil,
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
                else { throw ChatGPTFailure(kind: .invalidResponse) }
                var form = ChatGPTHTTP.form(server.revocationEndpoint, [
                    ("token", refreshToken), ("token_type_hint", "refresh_token"), ("client_id", clientID),
                ])
                form.timeoutInterval = 6
                let body = try await http.data(for: form, secrets: [refreshToken])
                guard body.isEmpty else { throw ChatGPTFailure(kind: .invalidResponse) }
                return
            } catch let failure as ChatGPTFailure where retry < 2 && (failure.kind == .network || failure.kind == .server) {
                try await Task.sleep(for: .milliseconds(400 * (1 << retry)))
            }
        }
    }

    private struct Discovery: Decodable {
        let issuer: String
        let revocationEndpoint: URL

        private enum CodingKeys: String, CodingKey {
            case issuer
            case revocationEndpoint = "revocation_endpoint"
        }
    }
}
