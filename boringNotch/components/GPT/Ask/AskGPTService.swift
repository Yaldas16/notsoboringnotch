import AppKit

enum AskGPTServiceInput {
    static func selectedText(from pasteboard: NSPasteboard) -> String? {
        let plain = pasteboard.string(forType: .string)
            ?? pasteboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType"))
        let rich = { pasteboard.data(forType: .rtf)
            ?? pasteboard.data(forType: NSPasteboard.PasteboardType("NeXT Rich Text Format v1.0 pasteboard type")) }
        let text = plain ?? rich().flatMap {
            // Refuse unexpectedly large rich-text data before invoking the document importer.
            guard $0.count <= 2 * 1024 * 1024 else { return nil }
            return NSAttributedString(rtf: $0, documentAttributes: nil)?.string
        }
        guard let text, text.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        return text
    }
}

@MainActor
final class AskGPTService: NSObject {
    static let shared = AskGPTService { AskGPTWindows.shared.show(selection: $0) }
    private let isEnabled: () -> Bool
    private let present: (String) -> Void

    init(isEnabled: @escaping () -> Bool = { AskGPTPreferences.isEnabled() }, present: @escaping (String) -> Void) {
        self.isEnabled = isEnabled
        self.present = present
    }

    @objc(askGPT:userData:error:)
    func askGPT(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard isEnabled() else {
            error?.pointee = String(localized: "Ask GPT for Selected Text is off in NotSoBoringNotch Settings → GPT.") as NSString
            return
        }
        guard let selection = AskGPTServiceInput.selectedText(from: pasteboard) else {
            error?.pointee = String(localized: "Ask GPT could not read the selected text. Try a smaller plain-text selection.") as NSString
            return
        }
        present(selection)
    }
}
