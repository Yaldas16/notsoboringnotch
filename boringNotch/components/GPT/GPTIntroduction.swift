import AppKit
import SwiftUI

enum GPTIntroductionPreference {
    private static let key = "gptIntroductionCompleted"

    static func shouldShow(firstLaunch: Bool, in defaults: UserDefaults = .standard) -> Bool {
        !firstLaunch && !defaults.bool(forKey: key)
    }

    static func complete(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }
}

@MainActor
final class GPTIntroductionWindow: NSObject, NSWindowDelegate {
    static let shared = GPTIntroductionWindow()
    private var controller: NSWindowController?

    func showIfNeeded(firstLaunch: Bool) {
        guard GPTIntroductionPreference.shouldShow(firstLaunch: firstLaunch), controller == nil else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 405),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = String(localized: "Welcome to NotSoBoringNotch")
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: GPTIntroductionView { [weak window] openChat in
            window?.close()
            if openChat { GPTChatWindowController.shared.open() }
        })
        window.delegate = self
        window.center()
        controller = NSWindowController(window: window)
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        GPTIntroductionPreference.complete()
        controller = nil
    }
}

private struct GPTIntroductionView: View {
    let finish: (Bool) -> Void

    @State private var showsWalkthrough = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let account = GPTAccountController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkle.bubble")
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            if showsWalkthrough {
                Text("Try Ask GPT").font(.title2.weight(.semibold))
                Text("Select text in a compatible app, right-click, and choose Services → Ask GPT. Write a question or pick a suggestion, then press Ask GPT when you’re ready.")
                Text("To turn on the service or assign a keyboard shortcut, open System Settings → Keyboard → Keyboard Shortcuts → Services.")
                    .foregroundStyle(.secondary)
                if account.active?.permitsInference != true {
                    GPTConnectButton(account: account)
                }
            } else {
                Text("Meet GPT in NotSoBoringNotch").font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 10) {
                    feature("bubble.left.and.text.bubble.right", "ChatGPT at the notch", "Open the GPT tab and choose Continue with ChatGPT to connect your account.")
                    feature("text.cursor", "Ask about selected text", "Use Ask GPT from Services in compatible apps such as TextEdit.")
                    feature("viewfinder", "Ask about an image", "Attach an image or choose Select Screen Area in the GPT toolbar.")
                    feature("arrow.up.left.and.arrow.down.right", "More room to chat", "Expand GPT into a resizable window that shares your conversation.")
                }
            }
            Spacer(minLength: 2)
            HStack {
                Button("Skip") { finish(false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if showsWalkthrough {
                    Button("Open GPT") { finish(true) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { showsWalkthrough = true }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 440, height: 405, alignment: .topLeading)
        .task { account.prepare() }
    }

    private func feature(_ icon: String, _ title: LocalizedStringKey, _ description: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 22)
                .padding(.top, 2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
