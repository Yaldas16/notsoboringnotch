import AppKit
import SwiftUI

@MainActor
struct AskGPTRequests {
    struct Request {
        let draft: AskGPTDraft
        let displayID: CGDirectDisplayID?
    }

    private(set) var isReady = false
    private(set) var current: Request?
    private var pending: [Request] = []

    var hasRequests: Bool { current != nil || !pending.isEmpty }

    mutating func enqueue(_ selection: String, on displayID: CGDirectDisplayID?) {
        guard current?.draft.selection != selection,
              !pending.contains(where: { $0.draft.selection == selection }) else { return }
        pending.append(Request(draft: AskGPTDraft(selection: selection), displayID: displayID))
    }

    mutating func markReady() { isReady = true }

    mutating func presentNext() -> Request? {
        guard isReady, current == nil, !pending.isEmpty else { return nil }
        let request = pending.removeFirst()
        current = request
        return request
    }

    mutating func finish() { current = nil }
}

@MainActor
final class AskGPTWindows: NSObject, NSWindowDelegate {
    static let shared = AskGPTWindows()
    private var requests = AskGPTRequests()
    private var controller: NSWindowController?
    private var awaitsActivation = false
    private var presentationScheduled = false

    var hasRequests: Bool { requests.hasRequests }

    func markReady() {
        requests.markReady()
        schedulePresentation()
    }

    func show(selection: String) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        requests.enqueue(selection, on: screen?.cgDisplayID)
        schedulePresentation()
    }

    private func schedulePresentation() {
        guard requests.isReady, requests.hasRequests, !presentationScheduled else { return }
        presentationScheduled = true
        // Return from the Services callback before asking AppKit to foreground the composer.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationScheduled = false
            if self.requests.current != nil, let window = self.controller?.window as? GPTComposerWindow {
                self.foreground(window)
            } else {
                self.showNext()
            }
        }
    }

    func applicationDidBecomeActive() {
        guard awaitsActivation, let window = controller?.window as? GPTComposerWindow,
              requests.current != nil else { return }
        awaitsActivation = false
        window.focusComposerWhenReady()
        window.makeKeyAndOrderFront(nil)
    }

    private func showNext() {
        guard let request = requests.presentNext() else { return }
        let window = composerWindow()
        window.contentView = NSHostingView(rootView: AskGPTComposer(draft: request.draft) { [weak self] submitted in
            self?.finish(submitted: submitted)
        })
        let screen = request.displayID.flatMap { id in NSScreen.screens.first { $0.cgDisplayID == id } } ?? NSScreen.main
        if let bounds = screen?.visibleFrame {
            let width = min(bounds.width, window.frame.width)
            let height = min(bounds.height, window.frame.height)
            window.setFrame(NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                   width: width, height: height), display: false)
        } else {
            window.center()
        }
        foreground(window)
    }

    private func composerWindow() -> GPTComposerWindow {
        if let window = controller?.window as? GPTComposerWindow { return window }

        let window = GPTComposerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 370),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = String(localized: "Ask GPT")
        window.contentMinSize = NSSize(width: 385, height: 330)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isRestorable = false
        window.animationBehavior = .utilityWindow
        window.delegate = self
        controller = NSWindowController(window: window)
        return window
    }

    private func foreground(_ window: GPTComposerWindow) {
        awaitsActivation = true
        if NSApp.isHidden { NSApp.unhide(nil) }
        window.orderFrontRegardless()
        if NSApp.isActive {
            applicationDidBecomeActive()
        } else {
            // Launch Services can activate this running instance for the explicit user request.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            configuration.createsNewApplicationInstance = false
            configuration.allowsRunningApplicationSubstitution = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                if error != nil {
                    Task { @MainActor in
                        if self.awaitsActivation { NSApp.activate() }
                    }
                }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(submitted: false)
        return false
    }

    private func finish(submitted: Bool) {
        guard let window = controller?.window as? GPTComposerWindow else { return }
        let screen = window.screen
        window.clearComposerFocus()
        awaitsActivation = false
        window.orderOut(nil)
        window.contentView = nil
        requests.finish()
        if requests.hasRequests {
            schedulePresentation()
        } else if submitted {
            GPTChatWindowController.shared.open(on: screen)
        }
    }
}

private struct AskGPTComposer: View {
    @Bindable var draft: AskGPTDraft
    let finish: (Bool) -> Void

    @AppStorage(AskGPTPreferences.enabledKey) private var serviceEnabled = AskGPTPreferences.serviceIsDeclared
    @AppStorage(AskGPTPreferences.languageKey) private var savedLanguage = ""
    @State private var expanded = false
    @State private var showsLanguages = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var language: AskGPTLanguage { AskGPTPreferences.language(savedLanguage) }
    private var conversation: GPTConversation { .shared }
    private var canSend: Bool {
        serviceEnabled && draft.canSubmit && conversation.canSubmit && !conversation.activity.isGenerating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    selection
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            suggestion(.explain)
                            suggestion(.summarize)
                            translate
                            suggestion(.rewrite)
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                suggestion(.explain)
                                suggestion(.summarize)
                            }
                            HStack(spacing: 6) {
                                translate
                                suggestion(.rewrite)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    GPTComposerEditor(draft: $draft.question, send: send,
                                      accessibilityLabel: String(localized: "Describe your question...")) { _ in }
                        .frame(height: 72)
                        .overlay(alignment: .topLeading) {
                            if draft.question.isEmpty {
                                Text("Describe your question...")
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 10)
                                    .padding(.top, 6)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary).allowsHitTesting(false) }
                    if let warning = draft.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    connectionStatus
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { finish(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Ask GPT", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
        }
        .padding(16)
        .task { GPTAccountController.shared.prepare() }
    }

    private func suggestion(_ suggestion: AskGPTDraft.Suggestion) -> some View {
        Button(language.question(for: suggestion)) { draft.apply(suggestion, language: language) }
    }

    private var translate: some View {
        Button(language.question(for: .translate)) { showsLanguages = true }
            .popover(isPresented: $showsLanguages, arrowEdge: .bottom) {
                AskGPTLanguagePicker(defaultLanguage: language) { target in
                    draft.apply(.translate, language: language, target: target)
                    showsLanguages = false
                }
            }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Selected Text").font(.subheadline.weight(.semibold))
                Spacer()
                if draft.canExpand {
                    Button(expanded ? "Show Less" : "Show More") {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { expanded.toggle() }
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft.selection, forType: .string)
                } label: {
                    Label("Copy selected text", systemImage: "document.on.document").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copy selected text")
            }
            if expanded {
                ScrollView {
                    Text(verbatim: draft.selection)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 110)
            } else {
                Text(verbatim: draft.preview)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var connectionStatus: some View {
        let account = GPTAccountController.shared
        if !serviceEnabled {
            Text("Ask GPT for Selected Text is off in Settings → GPT.")
                .foregroundStyle(.secondary)
                .font(.callout)
        } else if account.active?.permitsInference != true || account.restriction?.kind == .credential || account.restriction?.kind == .consent {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect ChatGPT to send this question.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                GPTConnectButton(account: account)
            }
        } else if conversation.activity.isGenerating {
            Text("Wait for the current GPT response or stop it in chat.")
                .foregroundStyle(.secondary)
                .font(.callout)
        } else if !conversation.canSubmit {
            Text(account.issue?.localizedDescription ?? "Waiting for an available ChatGPT model.")
                .foregroundStyle(.secondary)
                .font(.callout)
            if account.operation == nil {
                Button("Refresh Models", action: account.refreshModels)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func send() {
        guard canSend, let prompt = draft.prompt, conversation.submit(prompt) else { return }
        finish(true)
    }
}
