import Foundation
import Security
import XCTest
@testable import boringNotch

final class ChatGPTSessionTests: XCTestCase {
    func testStoresDistinctRegistrationsAndRequiresTheDirectGrant() async throws {
        let fixture = Fixture()
        let sessions = fixture.sessions()
        let host = try await sessions.hostID()
        XCTAssertTrue(host.hasPrefix("urn:uuid:"))
        let sameHost = try await fixture.sessions().hostID()
        XCTAssertEqual(sameHost, host)

        let first = try fixture.authorization(clientID: "first", subject: "one", scope: "openid")
        let snapshot = try await sessions.accept(first)
        XCTAssertTrue(snapshot.accounts[0].connected)
        XCTAssertFalse(snapshot.accounts[0].permitsInference)
        do {
            _ = try await sessions.access(for: first.clientID)
            XCTFail("A valid identity without direct scope must not authorize inference")
        } catch let failure as ChatGPTFailure {
            XCTAssertEqual(failure.kind, .consent)
        }

        let second = try fixture.authorization(clientID: "second", subject: "two")
        let switched = try await sessions.accept(second)
        XCTAssertEqual(switched.accounts.map(\.id), ["first", "second"])
        XCTAssertEqual(switched.activeID, "second")
        XCTAssertNotEqual(switched.accounts[0].label, switched.accounts[1].label)
        let mismatch = try fixture.authorization(clientID: "second", subject: "different")
        do {
            _ = try await sessions.accept(mismatch)
            XCTFail("A returning client must not accept a different identity")
        } catch let failure as ChatGPTFailure {
            XCTAssertEqual(failure.kind, .accountMismatch)
        }
        let unchanged = try await sessions.snapshot()
        XCTAssertEqual(unchanged.accounts.last?.identity.subject, "two")
    }

    func testRefreshRotatesOnceAcrossSimultaneousVaults() async throws {
        let fixture = Fixture()
        let original = try fixture.authorization(expiresIn: 1)
        let replacement = try fixture.tokens(scope: nil)
        await fixture.oauth.setRefresh(.success(replacement))
        let first = fixture.sessions()
        let second = fixture.sessions()
        _ = try await first.accept(original)
        async let left = first.access(for: original.clientID)
        async let right = second.access(for: original.clientID)
        let (firstAccess, secondAccess) = try await (left, right)
        XCTAssertTrue(firstAccess == replacement.accessToken && secondAccess == replacement.accessToken)
        let count = await fixture.oauth.refreshCount
        XCTAssertEqual(count, 1)
        let stored = try XCTUnwrap(fixture.storage.load().accounts.first?.tokens)
        XCTAssertTrue(stored.refresh == replacement.refreshToken)
        XCTAssertTrue(stored.permitsInference)
    }

    func testCancellingAConsumerPreservesRotatedTokens() async throws {
        let fixture = Fixture()
        let original = try fixture.authorization(expiresIn: 1)
        let replacement = try fixture.tokens()
        await fixture.oauth.setRefresh(.success(replacement))
        let sessions = fixture.sessions()
        _ = try await sessions.accept(original)
        let consumer = Task { try await sessions.access(for: original.clientID) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await fixture.oauth.refreshCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let count = await fixture.oauth.refreshCount
        XCTAssertEqual(count, 1)
        consumer.cancel()
        do {
            _ = try await consumer.value
            XCTFail("Cancelled consumer received a token")
        } catch is CancellationError {}
        let stored = try XCTUnwrap(fixture.storage.load().accounts.first?.tokens)
        XCTAssertTrue(stored.refresh == replacement.refreshToken)
    }

    func testServerFailureKeepsCredentialsAndTerminalRefreshClearsThem() async throws {
        let fixture = Fixture()
        let original = try fixture.authorization(expiresIn: 1)
        let sessions = fixture.sessions()
        _ = try await sessions.accept(original)

        await fixture.oauth.setRefresh(.failure(ChatGPTFailure(kind: .server)))
        do { _ = try await sessions.access(for: original.clientID); XCTFail("Expected temporary failure") }
        catch let failure as ChatGPTFailure { XCTAssertEqual(failure.kind, .server) }
        XCTAssertNotNil(try fixture.storage.load().accounts.first?.tokens)

        await fixture.oauth.setRefresh(.failure(ChatGPTFailure.remote(code: "refresh_token_reused")))
        do { _ = try await sessions.access(for: original.clientID); XCTFail("Expected revoked credentials") }
        catch let failure as ChatGPTFailure { XCTAssertEqual(failure.kind, .credential) }
        let ledger = try fixture.storage.load()
        XCTAssertTrue(ledger.accounts.first?.tokens == nil)
        XCTAssertEqual(ledger.accounts.first?.id, original.clientID)
    }

    func testSignOutKeepsRegistrationWhenRemoteRevocationIsUnconfirmed() async throws {
        let fixture = Fixture()
        let sessions = fixture.sessions()
        let original = try fixture.authorization()
        let host = try await sessions.hostID()
        _ = try await sessions.accept(original)
        await fixture.oauth.setRevocationFailure()
        let (snapshot, confirmed) = try await sessions.signOut(clientID: original.clientID)
        XCTAssertFalse(confirmed)
        XCTAssertEqual(snapshot.activeID, original.clientID)
        XCTAssertEqual(snapshot.accounts.first?.connected, false)
        let ledger = try fixture.storage.load()
        XCTAssertEqual(ledger.hostID, host)
        XCTAssertTrue(ledger.accounts.first?.tokens == nil)
    }

    func testSandboxedAppCanRoundTripAnIsolatedKeychainRecord() throws {
        let service = "com.yusuf.boringnotch.personal.chatgpt.test." + UUID().uuidString
        let storage = ChatGPTKeychain(service: service)
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }
        XCTAssertNil(try storage.load().hostID)
        try storage.save(ChatGPTLedger(hostID: "isolated-host-fixture"))
        XCTAssertEqual(try storage.load().hostID, "isolated-host-fixture")
        try storage.save(ChatGPTLedger(hostID: "updated-host-fixture"))
        XCTAssertEqual(try storage.load().hostID, "updated-host-fixture")
    }

    @MainActor
    func testKeychainRestoreRetriesOnlyByExplicitRequest() async {
        let fixture = Fixture()
        let controller = fixture.accountController()
        fixture.storage.rejectNextLoad()

        controller.prepare()
        await waitForAccountOperation(controller)
        XCTAssertTrue(controller.canRetryRestore)
        XCTAssertEqual(fixture.storage.loadCount, 1)

        controller.prepare()
        controller.prepare()
        XCTAssertNil(controller.operation)
        XCTAssertEqual(fixture.storage.loadCount, 1)

        controller.retryRestore()
        await waitForAccountOperation(controller)
        XCTAssertFalse(controller.canRetryRestore)
        XCTAssertNil(controller.issue)
        XCTAssertEqual(fixture.storage.loadCount, 2)
    }

    @MainActor
    func testFirstAccountRestoreKeepsAnUnsentDraft() async throws {
        let fixture = Fixture()
        let controller = fixture.accountController()
        let account = try fixture.authorization(scope: "openid")
        _ = try await fixture.sessions().accept(account)
        let conversation = GPTConversation.shared
        conversation.draft = "Question about a new attachment"
        defer { conversation.newChat() }

        controller.prepare()
        await waitForAccountOperation(controller)
        XCTAssertEqual(controller.activeID, account.clientID)
        XCTAssertEqual(conversation.draft, "Question about a new attachment")
    }

    @MainActor
    private func waitForAccountOperation(_ controller: GPTAccountController) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.operation != nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(controller.operation)
    }

    private final class Fixture {
        let storage = MemoryStorage()
        let oauth = ScriptedOAuth()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        deinit { try? FileManager.default.removeItem(at: directory) }

        @MainActor
        func accountController() -> GPTAccountController {
            let http = ChatGPTHTTP.shared
            let sessions = sessions()
            return GPTAccountController(oauth: ChatGPTOAuth(http: http), sessions: sessions,
                                        api: ChatGPTLiveAPI(http: http, sessions: sessions))
        }

        func sessions() -> ChatGPTSessions {
            let fixedTime = now
            return ChatGPTSessions(storage: storage, oauth: oauth, lockURL: directory.appendingPathComponent("session.lock"),
                                   now: { fixedTime })
        }

        func tokens(expiresIn: Int = 3600, scope: String? = ChatGPTEndpoints.directScope) throws -> ChatGPTTokenResponse {
            var fields: [String: Any] = [
                "access_token": UUID().uuidString, "refresh_token": UUID().uuidString,
                "id_token": UUID().uuidString, "token_type": "Bearer", "expires_in": expiresIn,
            ]
            if let scope { fields["scope"] = scope }
            return try JSONDecoder().decode(ChatGPTTokenResponse.self, from: JSONSerialization.data(withJSONObject: fields))
        }

        func authorization(clientID: String = "issued-fixture", subject: String = "one",
                           expiresIn: Int = 3600, scope: String = ChatGPTEndpoints.directScope) throws -> ChatGPTAuthorization {
            ChatGPTAuthorization(clientID: clientID,
                                 identity: ChatGPTIdentity(subject: subject, email: "test@example.com", name: nil),
                                 tokens: try tokens(expiresIn: expiresIn, scope: scope))
        }
    }

    private final class MemoryStorage: ChatGPTCredentialStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var ledger = ChatGPTLedger()
        private var loads = 0
        private var shouldRejectLoad = false

        var loadCount: Int { lock.withLock { loads } }
        func rejectNextLoad() { lock.withLock { shouldRejectLoad = true } }

        func load() throws -> ChatGPTLedger {
            try lock.withLock {
                loads += 1
                if shouldRejectLoad {
                    shouldRejectLoad = false
                    throw ChatGPTFailure(kind: .keychain)
                }
                return ledger
            }
        }

        func save(_ ledger: ChatGPTLedger) { lock.withLock { self.ledger = ledger } }
    }

    private actor ScriptedOAuth: ChatGPTTokenLifecycle {
        private var result: Result<ChatGPTTokenResponse, ChatGPTFailure> = .failure(ChatGPTFailure(kind: .server))
        private var revokeFails = false
        private(set) var refreshCount = 0

        func setRefresh(_ response: Result<ChatGPTTokenResponse, ChatGPTFailure>) { result = response }
        func setRevocationFailure() { revokeFails = true }

        func refresh(clientID: String, refreshToken: String) async throws -> ChatGPTTokenResponse {
            refreshCount += 1
            try await Task.sleep(for: .milliseconds(100))
            return try result.get()
        }

        func revoke(clientID: String, refreshToken: String) async throws {
            if revokeFails { throw ChatGPTFailure(kind: .network) }
        }
    }
}
