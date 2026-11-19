import Observation
import SwiftUI

struct GPTChatTranscript: View {
    let conversation: GPTConversation
    @State private var scroll = GPTTranscriptScroll()
    @Namespace private var scrollSpace

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(conversation.messages) { message in
                            GPTChatMessageView(message: message).equatable()
                        }
                        if conversation.activity != .idle {
                            activityRow
                        }
                        Color.clear.frame(height: 1).id(scrollSpace)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(
                                key: GPTTranscriptFrameKey.self,
                                value: content.frame(in: .named(scrollSpace))
                            )
                        }
                    }
                }
                .coordinateSpace(name: scrollSpace)
                .modifier(GPTScrollInteraction(state: scroll))
                .onPreferenceChange(GPTTranscriptFrameKey.self) { frame in
                    guard let frame else { return }
                    if scroll.update(frame: frame, viewportHeight: viewport.size.height) {
                        reader.scrollTo(scrollSpace, anchor: .bottom)
                    }
                }
                .onChange(of: conversation.conversationID) {
                    scroll = GPTTranscriptScroll()
                }
                .overlay(alignment: .bottomTrailing) {
                    if !scroll.followsLatest {
                        Button {
                            scroll.resumeFollowing()
                            reader.scrollTo(scrollSpace, anchor: .bottom)
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(8)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var activityRow: some View {
        HStack(spacing: 7) {
            switch conversation.activity {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView().controlSize(.small)
                Text("Waiting for a response…")
            case .streaming:
                Image(systemName: "waveform")
                Text("Streaming response…")
            case .stopped:
                Image(systemName: "stop.circle")
                Text("Generation stopped")
            case .failed(let message):
                Image(systemName: "exclamationmark.circle")
                Text(verbatim: message)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

@Observable
final class GPTTranscriptScroll {
    @ObservationIgnored private var previousLayout: (frame: CGRect, viewportHeight: CGFloat)?
    @ObservationIgnored var isUserScrolling = false
    private(set) var followsLatest = true

    func update(frame: CGRect, viewportHeight: CGFloat) -> Bool {
        defer { previousLayout = (frame, viewportHeight) }
        let distanceFromBottom = frame.maxY - viewportHeight
        if isUserScrolling {
            followsLatest = distanceFromBottom <= 18
            return false
        }

        if let previousLayout,
           abs(previousLayout.frame.height - frame.height) < 1,
           abs(previousLayout.viewportHeight - viewportHeight) < 1 {
            if abs(previousLayout.frame.minY - frame.minY) > 1 {
                followsLatest = distanceFromBottom <= 18
            }
            return false
        }
        return followsLatest && distanceFromBottom > 1
    }

    func resumeFollowing() {
        followsLatest = true
    }
}

private struct GPTScrollInteraction: ViewModifier {
    let state: GPTTranscriptScroll

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollPhaseChange { _, phase in
                state.isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
        } else {
            content
        }
    }
}

private struct GPTTranscriptFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

private struct GPTChatMessageView: View, Equatable {
    let message: GPTMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                message.role == .user ? "You" : "GPT",
                systemImage: message.role == .user ? "person.crop.circle" : "sparkle"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)

            if message.role == .user {
                if !message.images.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(message.images) { image in
                                GPTImagePreview(attachment: image, side: 104)
                            }
                        }
                    }
                }
                if !message.text.isEmpty {
                    Text(verbatim: message.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } else {
                GPTMarkdownView(source: message.text).equatable()
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}
