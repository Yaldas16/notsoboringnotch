import Foundation

enum ChatGPTEndpoints {
    static let issuer = "https://auth.openai.com"
    static let authorize = URL(string: issuer + "/api/accounts/authorize")!
    static let token = URL(string: issuer + "/api/accounts/oauth/token")!
    static let discovery = URL(string: issuer + "/.well-known/openid-configuration")!
    static let jwks = URL(string: issuer + "/.well-known/jwks.json")!
    static let resource = "https://api.openai.com/v1"
    static let models = URL(string: resource + "/models")!
    static let responses = URL(string: resource + "/responses")!
    static let dynamicClient = "dynamic_agent_client"
    static let directScope = "chatgpt.tokens.use.direct"
    static let scopes = "openid profile email offline_access resource.invoke " + directScope
}

struct ChatGPTFailure: LocalizedError, Sendable {
    enum Kind: Equatable, Sendable {
        case signedOut, consent, credential, invalidClient, invalidIdentity, accountMismatch
        case loopback, browser, timeout, keychain
        case ineligible, forbidden, usageLimit, modelUnavailable, imageUnsupported, server, network
        case incomplete, interrupted, invalidResponse, rejected
    }

    enum BodyShape: Sendable { case structuredError, admissionDetail, oauthError, other }

    var kind: Kind
    var status: Int? = nil
    var code: String? = nil
    var parameter: String? = nil
    var requestID: String? = nil
    var detail: String? = nil
    var bodyShape: BodyShape? = nil
    var trace: ChatGPTRequestTrace? = nil
    var protocolIssue: ChatGPTProtocolIssue? = nil
    var streamEnd: ChatGPTStreamEnd? = nil

    var summary: String {
        let message: String
        switch kind {
        case .signedOut: message = "Sign in with ChatGPT to send a message."
        case .consent: message = "ChatGPT plan usage needs your permission. You can enable it in GPT Settings."
        case .credential: message = "ChatGPT did not accept this session. Reconnect your account in GPT Settings."
        case .invalidClient: message = "ChatGPT did not accept this app registration."
        case .invalidIdentity: message = "The identity returned by ChatGPT could not be verified. Start sign-in again."
        case .accountMismatch: message = "Choose the ChatGPT account associated with this saved registration."
        case .loopback: message = "This Mac could not receive a secure sign-in callback. Start sign-in again."
        case .browser: message = "The system browser could not be opened."
        case .timeout: message = "Sign-in timed out. Start sign-in again."
        case .keychain: message = "NotSoBoringNotch could not access its credentials in Keychain."
        case .ineligible: message = "ChatGPT plan usage is unavailable for this account or workspace."
        case .forbidden: message = "ChatGPT denied access to this request."
        case .usageLimit: message = "A ChatGPT usage limit was reached. Review your plan and app limits in ChatGPT settings."
        case .modelUnavailable: message = protocolIssue?.message ?? "This model is unavailable. Refresh the model list and choose an available model."
        case .imageUnsupported: message = "The selected ChatGPT model or plan route rejected image input. Choose an image-capable model or start a text-only chat."
        case .server: message = "ChatGPT is temporarily unavailable. Try again later."
        case .network: message = "The connection to ChatGPT was interrupted. Check your connection and try again."
        case .incomplete: message = "ChatGPT returned an incomplete response."
        case .interrupted: message = "The response stream ended before ChatGPT confirmed completion."
        case .invalidResponse: message = protocolIssue?.message ?? "The app could not validate the ChatGPT response."
        case .rejected: message = "ChatGPT could not complete the request."
        }
        return message
    }

    var errorDescription: String? {
        let explanation = [summary, detail].compactMap { $0 }.joined(separator: " ")
        let stage = trace.map { "\($0.stage.action) — " } ?? ""
        let reference = ChatGPTRequestTrace.safeIdentifier(requestID).map { " Request ID \($0)." } ?? ""
        return stage + explanation + reference
    }

    var invalidatesRefreshToken: Bool {
        guard let code else { return false }
        return ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                "refresh_token_invalidated", "refresh_token_reused"].contains(code)
    }

    var pausesSending: Bool {
        [.credential, .invalidClient, .consent, .ineligible, .forbidden, .usageLimit, .modelUnavailable].contains(kind)
    }

    func explainingImageRejection(ifAttached hasImages: Bool) -> Self {
        guard hasImages else { return self }
        let field = parameter?.lowercased() ?? ""
        let message = detail?.lowercased() ?? ""
        let explicitModality = (message.contains("image") && message.contains("not support"))
            || message.contains("text-only")
        let inputCapability = code == "subscription_sharing_unsupported_capability"
            && (field == "input" || field.hasPrefix("input[") || field.contains("image"))
        guard inputCapability || (explicitModality && (status == 400 || status == 403 || status == 200)) else { return self }
        var explained = self
        explained.kind = .imageUnsupported
        return explained
    }

    static func response(_ response: HTTPURLResponse, data: Data, secrets: [String] = []) -> Self {
        if let structured = serviceError(data, status: response.statusCode, requestID: response.requestID, secrets: secrets) {
            return structured
        }
        var failure = remote(status: response.statusCode, code: nil, requestID: response.requestID, secrets: secrets)
        failure.bodyShape = .other
        return failure
    }

    static func serviceError(_ data: Data, status: Int? = nil, requestID: String? = nil,
                             secrets: [String] = []) -> Self? {
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data) else { return nil }
        let error = body.structured
        let shape: BodyShape
        if error != nil { shape = .structuredError }
        else if body.detail != nil { shape = .admissionDetail }
        else if body.oauthCode != nil { shape = .oauthError }
        else { return nil }
        var result = remote(status: status, code: error?.code ?? body.oauthCode, parameter: error?.param,
                            detail: body.detail ?? body.errorDescription ?? error?.message,
                            requestID: requestID, secrets: secrets)
        result.bodyShape = shape
        return result
    }

    static func remote(
        status: Int? = nil, code: String?, parameter: String? = nil,
        detail: String? = nil, requestID: String? = nil, secrets: [String] = []
    ) -> Self {
        let kind: Kind
        switch code {
        case "access_denied", "insufficient_scope", "chatpass_v2_scope_not_authorized": kind = .consent
        case "invalid_client", "unauthorized_client": kind = .invalidClient
        case "subscription_sharing_user_not_eligible": kind = .ineligible
        case "subscription_sharing_usage_limit_exceeded", "rate_limit_exceeded": kind = .usageLimit
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable", "server_error":
            kind = .server
        case "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
             "refresh_token_invalidated", "refresh_token_reused", "subscription_sharing_invalid_user":
            kind = .credential
        case "subscription_sharing_route_not_supported", "chatpass_v2_invalid_authorization_context":
            kind = .forbidden
        case "subscription_sharing_unsupported_capability" where parameter == "model": kind = .modelUnavailable
        case "model_not_found": kind = .modelUnavailable
        default:
            switch status ?? 0 {
            case 401: kind = .credential
            case 403: kind = .forbidden
            case 404: kind = .modelUnavailable
            case 429: kind = .usageLimit
            case 500...599: kind = .server
            default: kind = .rejected
            }
        }

        return Self(kind: kind, status: status, code: redacted(code, secrets: secrets),
                    parameter: redacted(parameter, secrets: secrets), requestID: redacted(requestID, secrets: secrets),
                    detail: redacted(detail, secrets: secrets))
    }

    private static func redacted(_ text: String?, secrets: [String]) -> String? {
        guard var text, !text.isEmpty else { return nil }
        for secret in secrets where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "[redacted]")
        }
        text = text.replacingOccurrences(
            of: #"(?i)\b(?:Bearer\s+\S+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)"#,
            with: "[redacted]", options: .regularExpression
        )
        return String(text.prefix(480))
    }

    struct StructuredError: Decodable {
        var code: String?
        var param: String?
        var message: String?

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Keys.self)
            code = try? fields.decode(String.self, forKey: .code)
            param = try? fields.decode(String.self, forKey: .param)
            message = try? fields.decode(String.self, forKey: .message)
        }

        private enum Keys: String, CodingKey { case code, param, message }
    }

    private struct ErrorBody: Decodable {
        let structured: StructuredError?
        let oauthCode: String?
        let detail: String?
        let errorDescription: String?

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            structured = try? fields.decode(StructuredError.self, forKey: .error)
            oauthCode = try? fields.decode(String.self, forKey: .error)
            detail = try? fields.decode(String.self, forKey: .detail)
            errorDescription = try? fields.decode(String.self, forKey: .errorDescription)
        }

        private enum CodingKeys: String, CodingKey {
            case error, detail
            case errorDescription = "error_description"
        }
    }
}

extension HTTPURLResponse {
    var requestID: String? {
        value(forHTTPHeaderField: "x-request-id") ?? value(forHTTPHeaderField: "openai-request-id")
    }
}

struct ChatGPTHTTP: Sendable {
    static let shared: Self = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 600
        return Self(session: URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil))
    }()

    let session: URLSession

    func load(_ request: URLRequest, secrets: [String], stage: ChatGPTRequestStage? = nil) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            let failure = ChatGPTFailure(kind: .network)
            guard let stage else { throw failure }
            let trace = ChatGPTRequestTrace(stage)
            trace.record("HTTP transport failed", failure: failure)
            throw trace.attach(failure)
        }
        guard let response = response as? HTTPURLResponse else {
            let failure = ChatGPTFailure(kind: .invalidResponse, protocolIssue: .nonHTTP)
            guard let stage else { throw failure }
            let trace = ChatGPTRequestTrace(stage)
            trace.record("Non-HTTP response", failure: failure)
            throw trace.attach(failure)
        }
        let trace = stage.map { ChatGPTRequestTrace($0, response, secrets: secrets) }
        guard response.statusCode == 200 else {
            let failure = ChatGPTFailure.response(response, data: data, secrets: secrets)
            trace?.record("HTTP error", failure: failure)
            throw trace?.attach(failure) ?? failure
        }
        trace?.record("HTTP response received")
        return (data, response)
    }

    func data(for request: URLRequest, secrets: [String] = []) async throws -> Data {
        try await load(request, secrets: secrets).0
    }

    func json<T: Decodable>(_ type: T.Type, for request: URLRequest, secrets: [String] = [],
                            stage: ChatGPTRequestStage? = nil) async throws -> T {
        let (body, response) = try await load(request, secrets: secrets, stage: stage)
        do { return try JSONDecoder().decode(type, from: body) }
        catch {
            let failure = ChatGPTFailure.serviceError(body, status: response.statusCode, requestID: response.requestID,
                                                       secrets: secrets)
                ?? ChatGPTFailure(kind: .invalidResponse, status: response.statusCode, requestID: response.requestID,
                                   protocolIssue: .invalidJSON)
            guard let stage else { throw failure }
            let trace = ChatGPTRequestTrace(stage, response, secrets: secrets)
            trace.record("JSON response could not be decoded", failure: failure)
            throw trace.attach(failure)
        }
    }

    static func form(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = fields.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        }.joined(separator: "&")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return request
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
