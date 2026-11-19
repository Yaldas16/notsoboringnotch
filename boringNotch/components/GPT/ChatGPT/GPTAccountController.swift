import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class GPTAccountController {
    enum Operation: Equatable {
        case restoring, connecting, loadingModels, signingOut
    }

    static let shared: GPTAccountController = {
        let http = ChatGPTHTTP.shared
        let oauth = ChatGPTOAuth(http: http)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let sessions = ChatGPTSessions(storage: ChatGPTKeychain(), oauth: oauth,
                                       lockURL: support.appendingPathComponent("Boring Notch Personal/ChatGPT/session.lock"))
        return GPTAccountController(oauth: oauth, sessions: sessions, api: ChatGPTLiveAPI(http: http, sessions: sessions))
    }()

    private(set) var accounts: [ChatGPTAccountSummary] = []
    private(set) var activeID: String?
    private(set) var operation: Operation?
    private(set) var models: [ChatGPTModel] = []
    private(set) var selectedModelID: String?
    private(set) var issue: ChatGPTFailure?
    private(set) var restriction: ChatGPTFailure?
    private(set) var revocationUnconfirmed = false

    @ObservationIgnored private var didAttemptRestore = false
    @ObservationIgnored private var work: Task<Void, Never>?
    private let oauth: ChatGPTOAuth
    private let sessions: ChatGPTSessions
    private let api: ChatGPTLiveAPI

    init(oauth: ChatGPTOAuth, sessions: ChatGPTSessions, api: ChatGPTLiveAPI) {
        self.oauth = oauth
        self.sessions = sessions
        self.api = api
    }

    var active: ChatGPTAccountSummary? { accounts.first { $0.id == activeID } }

    var chatService: ChatGPTLiveService? {
        guard operation == nil, restriction == nil,
              let account = active, account.connected, account.permitsInference,
              let selectedModelID, models.contains(where: { $0.slug == selectedModelID })
        else { return nil }

        return ChatGPTLiveService(api: api, clientID: account.id, model: selectedModelID) { [weak self] failure in
            guard !Task.isCancelled else { return }
            await self?.handleInferenceFailure(failure, clientID: account.id, model: selectedModelID)
        }
    }

    func prepare() {
        guard !didAttemptRestore, work == nil else { return }
        restore()
    }

    var canRetryRestore: Bool {
        operation == nil && active == nil && issue?.kind == .keychain
    }

    func retryRestore() {
        guard canRetryRestore else { return }
        restore()
    }

    private func restore() {
        didAttemptRestore = true
        perform(.restoring) { [self] in
            apply(try await sessions.snapshot())
            if restriction?.kind == .keychain { restriction = nil }
            if let account = active, account.permitsInference {
                try await fetchModels(for: account.id)
            }
        }
    }

    func connect(clientID: String?, requestConsent: Bool = false) {
        perform(.connecting) { [self] in
            let hostID = try await sessions.hostID()
            let validated = try await oauth.signIn(clientID: clientID, hostID: hostID, requestConsent: requestConsent)
            try Task.checkCancellation()
            let snapshot = try await sessions.accept(validated)
            apply(snapshot)
            restriction = nil
            didAttemptRestore = true
            if let account = active, account.permitsInference {
                operation = .loadingModels
                try await fetchModels(for: account.id)
                if !models.isEmpty, (try? await sessions.markPlanNoticeShown(for: account.id)) == true {
                    showPlanWelcome()
                }
            } else {
                models = []
                selectedModelID = nil
            }
        }
    }

    func cancelSignIn() {
        if operation == .connecting { work?.cancel() }
    }

    func refreshModels() {
        guard let account = active, account.connected, account.permitsInference else { return }
        perform(.loadingModels) { [self] in try await fetchModels(for: account.id) }
    }

    func signOut() {
        guard work == nil, let account = active, account.connected else { return }
        GPTConversation.shared.newChat()
        perform(.signingOut) { [self] in
            let result = try await sessions.signOut(clientID: account.id)
            apply(result.0)
            restriction = nil
            revocationUnconfirmed = !result.revocationConfirmed
            models = []
            selectedModelID = nil
        }
    }

    func selectModel(_ id: String?) {
        guard let id, models.contains(where: { $0.slug == id }) else { return }
        selectedModelID = id
        if restriction?.kind == .modelUnavailable {
            restriction = nil
            if issue?.kind == .modelUnavailable { issue = nil }
        }
    }

    private func apply(_ snapshot: ChatGPTAccountSnapshot) {
        let changedAccount = activeID != snapshot.activeID
        if changedAccount {
            // Before the first account is loaded, any image or question is still an unsent local draft.
            if activeID != nil { GPTConversation.shared.newChat() }
            restriction = nil
            models = []
            selectedModelID = nil
        }
        activeID = snapshot.activeID
        accounts = snapshot.accounts
    }

    private func fetchModels(for clientID: String) async throws {
        let catalog: [ChatGPTModel]
        do {
            catalog = try await api.models(for: clientID)
        } catch let failure as ChatGPTFailure where [.server, .network].contains(failure.kind) {
            try await Task.sleep(for: .milliseconds(600))
            catalog = try await api.models(for: clientID)
        }
        guard clientID == activeID else { return }
        models = catalog
        if !catalog.contains(where: { $0.slug == selectedModelID }) {
            selectedModelID = catalog.first?.slug
        }
        restriction = catalog.isEmpty ? ChatGPTFailure(kind: .modelUnavailable) : nil
        issue = restriction
    }

    private func showPlanWelcome() {
        let alert = NSAlert()
        alert.messageText = String(localized: "You're using your ChatGPT plan")
        alert.informativeText = String(localized: "Eligible requests use your ChatGPT plan. Review limits and credits in ChatGPT usage settings.")
        alert.addButton(withTitle: String(localized: "Got it"))
        NSApp.activate()
        alert.runModal()
    }

    private func handleInferenceFailure(_ failure: ChatGPTFailure, clientID: String, model: String) async {
        guard clientID == activeID, !Task.isCancelled else { return }
        if failure.kind == .modelUnavailable {
            models.removeAll { $0.slug == model }
            if selectedModelID != model { return }
            selectedModelID = nil
        }
        // The transcript handles transient failures. Account-wide restrictions pause sending.
        if failure.pausesSending || failure.kind == .signedOut || failure.kind == .keychain {
            restriction = failure
            issue = failure
        }
        if [.credential, .consent, .signedOut].contains(failure.kind),
           let snapshot = try? await sessions.snapshot(), clientID == activeID, !Task.isCancelled {
            apply(snapshot)
        }
    }

    private func perform(_ state: Operation, _ action: @escaping @MainActor () async throws -> Void) {
        guard work == nil else { return }
        let previousIssue = issue
        issue = nil
        revocationUnconfirmed = false
        operation = state
        work = Task {
            defer {
                operation = nil
                work = nil
            }

            do { try await action() }
            catch is CancellationError { issue = previousIssue }
            catch let failure as ChatGPTFailure {
                guard !Task.isCancelled else { issue = previousIssue; return }
                issue = failure
                guard state != .connecting || operation == .loadingModels else { return }
                if failure.pausesSending || [.signedOut, .keychain].contains(failure.kind) {
                    restriction = failure
                }
                if [.credential, .consent, .signedOut].contains(failure.kind),
                   let snapshot = try? await sessions.snapshot() {
                    apply(snapshot)
                }
            }
            catch { issue = ChatGPTFailure(kind: .invalidResponse) }
        }
    }
}
