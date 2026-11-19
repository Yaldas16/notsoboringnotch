import Darwin
import Foundation
import Security

struct ChatGPTStoredTokens: Codable, Sendable {
    let access: String
    let refresh: String?
    let idToken: String?
    let expiresAt: Date
    let earliestRefresh: Date?
    let scopes: Set<String>

    var permitsInference: Bool { scopes.contains(ChatGPTEndpoints.directScope) }

    init(response: ChatGPTTokenResponse, now: Date, previous: Self? = nil) throws {
        guard response.tokenType.lowercased() == "bearer", response.expiresIn.isFinite, response.expiresIn > 0,
              !response.accessToken.isEmpty, response.accessToken.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw ChatGPTFailure(kind: .invalidResponse) }
        let refresh = response.refreshToken.flatMap { $0.isEmpty ? nil : $0 }
        if previous != nil, refresh == nil { throw ChatGPTFailure(kind: .invalidResponse) }

        access = response.accessToken
        self.refresh = refresh
        // Refresh updates the OAuth grant. Keep the ID token verified during browser sign-in.
        idToken = previous?.idToken ?? response.idToken
        expiresAt = now.addingTimeInterval(response.expiresIn)
        earliestRefresh = response.earliestRefresh
        scopes = response.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? previous?.scopes ?? []
    }
}

struct ChatGPTAccount: Identifiable, Codable, Sendable {
    let id: String
    let ordinal: Int
    var identity: ChatGPTIdentity
    var tokens: ChatGPTStoredTokens?

    var summary: ChatGPTAccountSummary {
        ChatGPTAccountSummary(id: id, ordinal: ordinal, identity: identity, connected: tokens != nil,
                              permitsInference: tokens?.permitsInference == true)
    }
}

struct ChatGPTAccountSummary: Identifiable, Equatable, Sendable {
    let id: String
    let ordinal: Int
    let identity: ChatGPTIdentity
    let connected: Bool
    let permitsInference: Bool

    var label: String {
        let account = "Account \(ordinal)"
        guard let identityLabel = identity.email ?? identity.name, !identityLabel.isEmpty else { return account }
        return account + " · " + identityLabel
    }
}

struct ChatGPTLedger: Codable, Sendable {
    var hostID: String?
    var activeID: String?
    var accounts: [ChatGPTAccount] = []
    var planNoticeShown: Set<String>?

    var snapshot: ChatGPTAccountSnapshot {
        ChatGPTAccountSnapshot(activeID: activeID, accounts: accounts.map(\.summary))
    }
}

struct ChatGPTAccountSnapshot: Sendable {
    let activeID: String?
    let accounts: [ChatGPTAccountSummary]
}

protocol ChatGPTCredentialStorage: Sendable {
    func load() throws -> ChatGPTLedger
    func save(_ ledger: ChatGPTLedger) throws
}

struct ChatGPTKeychain: ChatGPTCredentialStorage {
    var service = "com.yusuf.boringnotch.personal.chatgpt"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "chatgpt-registrations-v1",
        ]
    }

    func load() throws -> ChatGPTLedger {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return ChatGPTLedger() }
        guard status == errSecSuccess, let data = result as? Data,
              let ledger = try? JSONDecoder().decode(ChatGPTLedger.self, from: data)
        else { throw ChatGPTFailure(kind: .keychain) }
        return ledger
    }

    func save(_ ledger: ChatGPTLedger) throws {
        guard let data = try? JSONEncoder().encode(ledger) else { throw ChatGPTFailure(kind: .keychain) }
        let values = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ChatGPTFailure(kind: .keychain) }
        } else if status != errSecSuccess {
            throw ChatGPTFailure(kind: .keychain)
        }
    }
}

actor ChatGPTSessions {
    private let storage: any ChatGPTCredentialStorage
    private let oauth: any ChatGPTTokenLifecycle
    private let lockURL: URL
    private let now: @Sendable () -> Date

    init(storage: any ChatGPTCredentialStorage, oauth: any ChatGPTTokenLifecycle, lockURL: URL,
         now: @escaping @Sendable () -> Date = { .now }) {
        self.storage = storage
        self.oauth = oauth
        self.lockURL = lockURL
        self.now = now
    }

    func snapshot() throws -> ChatGPTAccountSnapshot {
        try storage.load().snapshot
    }

    func hostID() async throws -> String {
        try await withLock {
            var ledger = try storage.load()
            if let hostID = ledger.hostID { return hostID }
            let hostID = "urn:uuid:" + UUID().uuidString.lowercased()
            ledger.hostID = hostID
            try storage.save(ledger)
            return hostID
        }
    }

    func accept(_ authorization: ChatGPTAuthorization) async throws -> ChatGPTAccountSnapshot {
        try await withLock {
            var ledger = try storage.load()
            let tokens = try ChatGPTStoredTokens(response: authorization.tokens, now: now())
            if let index = ledger.accounts.firstIndex(where: { $0.id == authorization.clientID }) {
                guard ledger.accounts[index].identity.subject == authorization.identity.subject else {
                    throw ChatGPTFailure(kind: .accountMismatch)
                }
                ledger.accounts[index].identity = authorization.identity
                ledger.accounts[index].tokens = tokens
            } else {
                let ordinal = (ledger.accounts.map(\.ordinal).max() ?? 0) + 1
                ledger.accounts.append(ChatGPTAccount(id: authorization.clientID, ordinal: ordinal,
                                                      identity: authorization.identity, tokens: tokens))
            }
            ledger.activeID = authorization.clientID
            try storage.save(ledger)
            return ledger.snapshot
        }
    }

    func access(for clientID: String, replacing rejectedToken: String? = nil) async throws -> String {
        try Task.checkCancellation()
        // A cancelled generation must not discard the replacement after the server rotates a refresh token.
        let renewal = Task { try await accessUnderLock(for: clientID, replacing: rejectedToken) }
        let token = try await renewal.value
        try Task.checkCancellation()
        return token
    }

    private func accessUnderLock(for clientID: String, replacing rejectedToken: String?) async throws -> String {
        try await withLock {
            var ledger = try storage.load()
            guard ledger.activeID == clientID, let index = ledger.accounts.firstIndex(where: { $0.id == clientID }),
                  let tokens = ledger.accounts[index].tokens else { throw ChatGPTFailure(kind: .signedOut) }
            guard tokens.permitsInference else { throw ChatGPTFailure(kind: .consent) }

            let time = now()
            let rejected = rejectedToken == tokens.access
            let canUse = !rejected && tokens.expiresAt > time
            let canRefresh = (tokens.earliestRefresh ?? .distantPast) <= time && tokens.refresh != nil
            if canUse && (tokens.expiresAt.timeIntervalSince(time) > 60 || !canRefresh) { return tokens.access }
            guard canRefresh, let refresh = tokens.refresh else { throw ChatGPTFailure(kind: .credential) }

            let response: ChatGPTTokenResponse
            do {
                response = try await oauth.refresh(clientID: clientID, refreshToken: refresh)
            } catch let failure as ChatGPTFailure where failure.invalidatesRefreshToken {
                ledger.accounts[index].tokens = nil
                try storage.save(ledger)
                throw failure
            }
            let replacement = try ChatGPTStoredTokens(response: response, now: now(), previous: tokens)
            ledger.accounts[index].tokens = replacement
            try storage.save(ledger)
            guard replacement.permitsInference else { throw ChatGPTFailure(kind: .consent) }
            return replacement.access
        }
    }

    func markPlanNoticeShown(for clientID: String) async throws -> Bool {
        try await withLock {
            var ledger = try storage.load()
            guard ledger.activeID == clientID,
                  ledger.accounts.first(where: { $0.id == clientID })?.tokens?.permitsInference == true,
                  ledger.planNoticeShown?.contains(clientID) != true
            else { return false }
            ledger.planNoticeShown = (ledger.planNoticeShown ?? []).union([clientID])
            try storage.save(ledger)
            return true
        }
    }

    func signOut(clientID: String) async throws -> (ChatGPTAccountSnapshot, revocationConfirmed: Bool) {
        try await withLock {
            var ledger = try storage.load()
            guard let index = ledger.accounts.firstIndex(where: { $0.id == clientID }) else {
                return (ledger.snapshot, true)
            }
            var confirmed = true
            if let refreshToken = ledger.accounts[index].tokens?.refresh {
                do { try await oauth.revoke(clientID: clientID, refreshToken: refreshToken) }
                catch { confirmed = false }
            }
            ledger.accounts[index].tokens = nil
            try storage.save(ledger)
            return (ledger.snapshot, confirmed)
        }
    }

    private func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw ChatGPTFailure(kind: .keychain)
        }
        // The empty lock file coordinates Keychain mutations between local app processes.
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ChatGPTFailure(kind: .keychain) }
        defer { close(fd) }

        let deadline = ContinuousClock.now.advanced(by: .seconds(75))
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard (errno == EWOULDBLOCK || errno == EINTR), ContinuousClock.now < deadline else {
                throw ChatGPTFailure(kind: .keychain)
            }
            try await Task.sleep(for: .milliseconds(60))
        }
        try Task.checkCancellation()
        return try await operation()
    }
}
