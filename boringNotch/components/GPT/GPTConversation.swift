import Foundation
import Observation

@MainActor
@Observable
final class GPTConversation {
    enum Activity: Equatable {
        case idle
        case loading
        case streaming
        case stopped
        case failed(String)

        var isGenerating: Bool {
            self == .loading || self == .streaming
        }
    }

    static let shared = GPTConversation { GPTAccountController.shared.chatService }

    private(set) var messages: [GPTMessage] = []
    private(set) var activity: Activity = .idle
    private(set) var conversationID = UUID()
    var draft = ""

    private(set) var draftImages: [GPTImageAttachment] = []
    private(set) var isImportingImages = false
    private(set) var imageFeedback: String?
    @ObservationIgnored private var imageImport: Task<Void, Never>?

    private let makeService: @MainActor () -> (any GPTChatService)?
    @ObservationIgnored private var generationID: UUID?
    @ObservationIgnored private var generation: Task<Void, Never>?

    init(service: any GPTChatService) {
        makeService = { service }
    }

    init(makeService: @escaping @MainActor () -> (any GPTChatService)?) {
        self.makeService = makeService
    }

    deinit {
        generation?.cancel()
        imageImport?.cancel()
    }

    var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty)
            && canSubmit && !isImportingImages && imageLimitWarning == nil
    }

    var canSubmit: Bool { makeService() != nil }

    var canStartNewChat: Bool {
        !messages.isEmpty || !draft.isEmpty || !draftImages.isEmpty || isImportingImages
    }

    func sendDraft() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, submit(prompt, images: draftImages) else { return }
        draft = ""
        draftImages.removeAll()
        imageFeedback = nil
    }

    @discardableResult
    func submit(_ prompt: String, images: [GPTImageAttachment] = []) -> Bool {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty,
              images.count <= GPTImageAttachment.maxDraftImages,
              !exceedsImageLimit(adding: images), let service = makeService() else { return false }

        cancelGeneration()
        messages.append(GPTMessage(role: .user, text: prompt, images: images))
        activity = .loading

        let id = UUID()
        generationID = id
        let stream = service.response(to: messages)
        generation = Task { [weak self] in
            do {
                for try await chunk in stream {
                    guard !Task.isCancelled, self?.generationID == id else { return }
                    if !chunk.isEmpty { self?.append(chunk) }
                }
                self?.finish(id, with: .idle)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish(id, with: .failed(error.localizedDescription))
            }
        }
        return true
    }

    func stop() {
        guard activity.isGenerating else { return }
        cancelGeneration()
        activity = .stopped
    }

    func newChat() {
        cancelGeneration()
        draft = ""
        draftImages.removeAll()
        imageImport?.cancel()
        imageImport = nil
        isImportingImages = false
        imageFeedback = nil
        messages.removeAll()
        activity = .idle
        conversationID = UUID()
    }

    var imageLimitWarning: String? {
        exceedsImageLimit(adding: draftImages)
            ? String(localized: "This chat would exceed 24 MB of image context. Remove an attachment or start a new chat.")
            : nil
    }

    func removeImage(_ id: UUID) {
        draftImages.removeAll { $0.id == id }
        imageFeedback = nil
    }

    func importImages(onResult: ((GPTImageImport) -> Void)? = nil,
                      _ operation: @escaping @MainActor (Int) async -> GPTImageImport) {
        guard !isImportingImages else { return }
        let remaining = GPTImageAttachment.maxDraftImages - draftImages.count
        guard remaining > 0 else {
            let warning = GPTImageAttachment.Failure.tooMany
            imageFeedback = warning.localizedDescription
            onResult?(GPTImageImport(warning: warning))
            return
        }

        let id = conversationID
        imageFeedback = nil
        isImportingImages = true
        imageImport = Task { [weak self] in
            let result = await operation(remaining)
            guard let self, conversationID == id, !Task.isCancelled else { return }
            isImportingImages = false
            imageImport = nil
            draftImages.append(contentsOf: result.attachments.prefix(remaining))
            imageFeedback = result.warning?.localizedDescription
            onResult?(result)
        }
    }

    private func exceedsImageLimit(adding images: [GPTImageAttachment]) -> Bool {
        guard !images.isEmpty else { return false }
        let sentBytes = messages.reduce(0) { total, message in
            total + message.images.reduce(0) { $0 + $1.bytes.count }
        }
        return sentBytes + images.reduce(0) { $0 + $1.bytes.count } > GPTImageAttachment.maxConversationImageBytes
    }

    private func append(_ chunk: String) {
        if activity == .loading {
            messages.append(GPTMessage(role: .assistant, text: chunk))
            activity = .streaming
        } else {
            messages[messages.count - 1].text += chunk
        }
    }

    private func finish(_ id: UUID, with activity: Activity) {
        guard generationID == id else { return }
        generationID = nil
        generation = nil
        self.activity = activity
    }

    private func cancelGeneration() {
        generationID = nil
        generation?.cancel()
        generation = nil
    }
}
