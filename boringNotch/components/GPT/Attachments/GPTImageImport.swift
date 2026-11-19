import AppKit
import UniformTypeIdentifiers

struct GPTImageImport: Sendable {
    var attachments: [GPTImageAttachment] = []
    var warning: GPTImageAttachment.Failure?

    private mutating func append(_ result: Result<GPTImageAttachment, GPTImageAttachment.Failure>) {
        switch result {
        case .success(let attachment): attachments.append(attachment)
        case .failure(let failure): if warning == nil { warning = failure }
        }
    }

    static func files(_ urls: [URL], limit: Int) async -> Self {
        let work = Task.detached(priority: .userInitiated) {
            var result = Self()
            for url in urls.prefix(limit) {
                guard !Task.isCancelled else { return Self() }
                result.append(read { try GPTImageAttachment.load(file: url) })
            }
            if urls.count > limit, result.warning == nil { result.warning = .tooMany }
            return result
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    static func bytes(_ data: Data) async -> Self {
        await Task.detached(priority: .userInitiated) {
            var result = Self()
            result.append(read { try GPTImageAttachment.load(data: data) })
            return result
        }.value
    }

    @MainActor
    static func dropped(_ providers: [NSItemProvider], limit: Int) async -> Self {
        var result = Self()
        for provider in providers.prefix(limit) {
            guard !Task.isCancelled else { break }
            result.append(await load(provider))
        }
        if providers.count > limit, result.warning == nil { result.warning = .tooMany }
        return result
    }

    @MainActor
    static func pasteboardBytes(_ pasteboard: NSPasteboard) -> Data? {
        let types = GPTImageAttachment.acceptedTypes.map { NSPasteboard.PasteboardType($0.identifier) }
        guard let type = pasteboard.availableType(from: types) else { return nil }
        return pasteboard.data(forType: type)
    }

    @MainActor
    private static func load(_ provider: NSItemProvider) async -> Result<GPTImageAttachment, GPTImageAttachment.Failure> {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await withCheckedContinuation { completion in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    let url: URL? = (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url else { completion.resume(returning: .failure(.unreadable)); return }
                    // Read inside the provider callback while its transfer permission is available.
                    completion.resume(returning: read { try GPTImageAttachment.load(file: url) })
                }
            }
        }

        guard let type = GPTImageAttachment.acceptedTypes.first(where: {
            provider.hasItemConformingToTypeIdentifier($0.identifier)
        }) else { return .failure(.unsupported) }
        return await withCheckedContinuation { completion in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { completion.resume(returning: .failure(.unreadable)); return }
                completion.resume(returning: read { try GPTImageAttachment.load(file: url) })
            }
        }
    }

    private static func read(_ transform: () throws -> GPTImageAttachment) -> Result<GPTImageAttachment, GPTImageAttachment.Failure> {
        do { return .success(try transform()) }
        catch let failure as GPTImageAttachment.Failure { return .failure(failure) }
        catch { return .failure(.unreadable) }
    }
}
