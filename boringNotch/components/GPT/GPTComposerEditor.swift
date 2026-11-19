import AppKit
import SwiftUI

struct GPTComposerEditor: NSViewRepresentable {
    @Binding var draft: String
    let send: () -> Void
    var accessibilityLabel = String(localized: "Message GPT")
    var pasteImage: ((NSPasteboard) -> Bool)?
    let focusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(draft: $draft)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let editor = GPTComposerTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
        editor.delegate = context.coordinator
        editor.importsGraphics = false
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 5, height: 6)
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.setAccessibilityLabel(accessibilityLabel)
        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? GPTComposerTextView else { return }
        context.coordinator.draft = $draft
        editor.onFocus = focusChanged
        editor.onSend = send
        editor.onPasteImage = pasteImage
        if editor.string != draft, !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = draft
            let length = (draft as NSString).length
            let location = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let editor = scrollView.documentView as? GPTComposerTextView else { return }
        editor.onFocus = nil
        editor.onSend = nil
        editor.onPasteImage = nil
        editor.delegate = nil
        editor.releaseNotchFocus()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var draft: Binding<String>

        init(draft: Binding<String>) {
            self.draft = draft
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            if draft.wrappedValue != editor.string { draft.wrappedValue = editor.string }
        }
    }
}

final class GPTComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    var onPasteImage: ((NSPasteboard) -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let panel = window as? BoringNotchSkyLightWindow {
            panel.wantsKeyForTextInput = true
            panel.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocus?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        (window as? BoringNotchSkyLightWindow)?.wantsKeyForTextInput = false
        onFocus?(false)
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window = window as? GPTComposerWindow, window.initialFirstResponder === self {
            window.initialFirstResponder = nil
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let newWindow {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification, object: newWindow
            )
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? GPTComposerWindow)?.registerComposerEditor(self)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if isReturn, !hasMarkedText() {
            if modifiers.isEmpty {
                onSend?()
                return
            }
            if modifiers == .shift {
                insertNewline(nil)
                return
            }
        }

        let wasComposing = hasMarkedText()
        super.keyDown(with: event)
        if wasComposing, !hasMarkedText() { didChangeText() }
    }

    override func paste(_ sender: Any?) {
        if onPasteImage?(NSPasteboard.general) == true { return }
        super.paste(sender)
    }

    func releaseNotchFocus() {
        guard let panel = window as? BoringNotchSkyLightWindow, panel.firstResponder === self else { return }
        panel.makeFirstResponder(nil)
        panel.wantsKeyForTextInput = false
    }

    @objc private func windowDidResignKey() {
        releaseNotchFocus()
    }
}

@MainActor
final class GPTComposerWindow: NSWindow {
    private var needsComposerFocus = false

    func registerComposerEditor(_ editor: NSView) {
        initialFirstResponder = editor
        focusComposerIfReady()
    }

    func focusComposerWhenReady() {
        needsComposerFocus = true
        focusComposerIfReady()
    }

    func clearComposerFocus() {
        needsComposerFocus = false
        initialFirstResponder = nil
    }

    override func becomeKey() {
        super.becomeKey()
        focusComposerIfReady()
    }

    private func focusComposerIfReady() {
        guard needsComposerFocus, isKeyWindow, let editor = initialFirstResponder else { return }
        if makeFirstResponder(editor) { needsComposerFocus = false }
    }
}
