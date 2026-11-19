import SwiftUI
import UniformTypeIdentifiers

struct GPTChatView: View {
    let conversation: GPTConversation
    var openWindow: (() -> Void)?
    var editingChanged: (Bool) -> Void = { _ in }
    var attachmentPopoverChanged: (Bool) -> Void = { _ in }

    @State private var isEditing = false
    @State private var isChoosingImages = false
    @State private var showsAttachmentOptions = false
    @State private var isImageDropTargeted = false
    private let account = GPTAccountController.shared

    private var isInNotch: Bool { openWindow != nil }
    private var isHandlingAttachment: Bool { showsAttachmentOptions || isChoosingImages || conversation.isImportingImages }
    private var imageControlsDisabled: Bool { isChoosingImages || conversation.isImportingImages }

    var body: some View {
        if isInNotch {
            chat
        } else {
            chat
                .onDrop(of: [.fileURL] + GPTImageAttachment.acceptedTypes, isTargeted: $isImageDropTargeted) { providers in
                    guard account.active?.permitsInference == true, !conversation.isImportingImages else { return false }
                    conversation.importImages { await GPTImageImport.dropped(providers, limit: $0) }
                    return true
                }
                .overlay {
                    if isImageDropTargeted, account.active?.permitsInference == true {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var chat: some View {
        @Bindable var conversation = conversation
        return VStack(spacing: isInNotch ? 8 : 12) {
            header

            Group {
                if account.active?.permitsInference != true {
                    disconnectedState
                } else if conversation.messages.isEmpty {
                    emptyState
                } else {
                    GPTChatTranscript(conversation: conversation)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 13))

            attachmentPreview
            if account.active?.permitsInference == true || !conversation.draftImages.isEmpty || !conversation.draft.isEmpty {
                composer(draft: $conversation.draft)
            }
        }
        .padding(isInNotch ? 4 : 18)
        .task { account.prepare() }
        .onChange(of: isHandlingAttachment) { _, active in
            attachmentPopoverChanged(active)
        }
        .onDisappear {
            if isEditing { editingChanged(false) }
            if isHandlingAttachment { attachmentPopoverChanged(false) }
            showsAttachmentOptions = false
        }
    }

    private func composer(draft: Binding<String>) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            GPTComposerEditor(draft: draft, send: conversation.sendDraft, pasteImage: pasteImage) { focused in
                isEditing = focused
                editingChanged(focused)
            }
            .frame(height: isInNotch ? 46 : 66)
            .overlay(alignment: .topLeading) {
                if conversation.draft.isEmpty, !isEditing {
                    Text("Message GPT")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 10)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(.quinary, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isEditing ? Color.accentColor : Color.secondary.opacity(0.23))
                    .allowsHitTesting(false)
            }
            if conversation.activity.isGenerating {
                Button(action: conversation.stop) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .help("Stop generation")
                .accessibilityLabel("Stop generation")
            }
            Button(action: conversation.sendDraft) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!conversation.canSend)
            .help("Send message")
            .accessibilityLabel("Send message")
        }
        .controlSize(.large)
    }

    private var imageActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                toolbarButton("Attach Image", icon: "paperclip", action: chooseImages)
                if #available(macOS 15.2, *) {
                    toolbarButton("Select Screen Area", icon: "viewfinder", action: captureScreenArea)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            toolbarButton("Image Options", icon: "paperclip") { showsAttachmentOptions.toggle() }
                .popover(isPresented: $showsAttachmentOptions, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Attach Image…", systemImage: "paperclip") {
                            showsAttachmentOptions = false
                            chooseImages()
                        }
                        if #available(macOS 15.2, *) {
                            Button("Select Screen Area", systemImage: "viewfinder") {
                                showsAttachmentOptions = false
                                captureScreenArea()
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(12)
                }
        }
        .disabled(imageControlsDisabled)
    }

    private func toolbarButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(Text(title))
        .help(Text(title))
    }

    @ViewBuilder private var attachmentPreview: some View {
        if !conversation.draftImages.isEmpty || conversation.isImportingImages {
            HStack(spacing: 7) {
                ForEach(conversation.draftImages) { image in
                    GPTImagePreview(attachment: image, side: 48)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                conversation.removeImage(image.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.78))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove image")
                            .help("Remove image")
                        }
                }
                if conversation.isImportingImages {
                    ProgressView().controlSize(.small).accessibilityLabel("Preparing images")
                }
                Spacer(minLength: 0)
            }
        }
        if let warning = conversation.imageLimitWarning ?? conversation.imageFeedback {
            Text(warning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = GPTImageAttachment.acceptedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Attach")
        let id = conversation.conversationID
        isChoosingImages = true
        NSApp.activate()
        panel.begin { result in
            Task { @MainActor in
                isChoosingImages = false
                guard result == .OK, conversation.conversationID == id else { return }
                let urls = panel.urls
                conversation.importImages { await GPTImageImport.files(urls, limit: $0) }
            }
        }
    }

    private func pasteImage(_ pasteboard: NSPasteboard) -> Bool {
        guard let data = GPTImageImport.pasteboardBytes(pasteboard) else { return false }
        conversation.importImages { _ in await GPTImageImport.bytes(data) }
        return true
    }

    @available(macOS 15.2, *)
    private func captureScreenArea() {
        GPTScreenAreaCapture.attach(to: conversation)
    }

    private var header: some View {
        VStack(spacing: 5) {
            headerActions

            if let issue = account.restriction ?? account.issue, account.active?.permitsInference == true {
                HStack {
                    Text(issue.localizedDescription)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if issue.kind == .credential || issue.kind == .consent || issue.kind == .signedOut {
                        GPTConnectButton(account: account)
                    } else if issue.kind == .modelUnavailable || issue.kind == .usageLimit || !issue.pausesSending {
                        Button("Refresh Models", action: account.refreshModels)
                            .disabled(account.operation != nil)
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if account.active?.permitsInference == true {
                if !account.models.isEmpty {
                    GPTModelPicker(account: account)
                        .labelsHidden()
                        .frame(maxWidth: isInNotch ? 132 : 210)
                } else if account.operation != nil {
                    ProgressView().controlSize(.small)
                }
                Text(account.restriction == nil && !account.models.isEmpty ? "Using ChatGPT plan" : "ChatGPT plan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            } else {
                Text("ChatGPT")
                    .font(.caption.weight(.semibold))
            }
            Spacer(minLength: 4)

            if account.active?.permitsInference == true {
                imageActions
            }

            toolbarButton("New Chat", icon: "square.and.pencil", action: conversation.newChat)
                .fixedSize()
                .disabled(!conversation.canStartNewChat)

            if let openWindow {
                toolbarButton("Open chat in a window", icon: "arrow.up.left.and.arrow.down.right", action: openWindow)
                    .fixedSize()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: isInNotch ? 23 : 32, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Start a conversation")
                .font(.headline)
            Text("This conversation stays in memory until you start a new chat or quit.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 325)
        }
        .padding(12)
    }

    private var disconnectedState: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Connect your ChatGPT account")
                    .font(.headline)
                Text(account.issue?.localizedDescription ?? "Use your ChatGPT plan for eligible AI requests in NotSoBoringNotch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 375)

                GPTConnectButton(account: account)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
        }
    }
}
