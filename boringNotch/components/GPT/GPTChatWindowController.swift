import AppKit
import SwiftUI

@MainActor
final class GPTChatWindowController: NSWindowController {
    static let shared = GPTChatWindowController(conversation: .shared)

    init(conversation: GPTConversation) {
        let window = GPTComposerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 510),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "GPT Chat")
        window.contentMinSize = NSSize(width: 420, height: 330)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GPTChatView(conversation: conversation))
        super.init(window: window)
        NotificationCenter.default.addObserver(self, selector: #selector(finishActivation),
                                               name: NSApplication.didBecomeActiveNotification, object: NSApp)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var hasPositionedWindow = false
    private var awaitsActivation = false

    func open(on screen: NSScreen? = NSScreen.main, focusComposer: Bool = false) {
        guard let window = window as? GPTComposerWindow else { return }
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if !hasPositionedWindow || (!window.isVisible && window.screen != screen) {
            if let screen {
                let visibleFrame = screen.visibleFrame
                let width = min(window.frame.width, visibleFrame.width)
                let height = min(window.frame.height, visibleFrame.height)
                window.setFrame(NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2,
                                       width: width, height: height), display: false)
            } else {
                window.center()
            }
            hasPositionedWindow = true
        }
        if focusComposer { window.focusComposerWhenReady() }
        awaitsActivation = true
        window.orderFrontRegardless()
        if NSApp.isActive { finishActivation() }
        else { NSApp.activate() }
    }

    @objc private func finishActivation() {
        guard awaitsActivation else { return }
        awaitsActivation = false
        if window?.isVisible == true { window?.makeKeyAndOrderFront(nil) }
    }
}
