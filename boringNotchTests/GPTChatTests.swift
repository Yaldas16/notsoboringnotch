import SwiftUI
import XCTest
@testable import boringNotch

@MainActor
final class GPTChatTests: XCTestCase {
    func testStreamingAppendsToOneAssistantMessage() async {
        let stream = ResponseStream.makeStream()
        let conversation = GPTConversation(service: Service(responses: ["Hello": stream.stream]))

        conversation.draft = "  Hello\n"
        conversation.sendDraft()
        XCTAssertEqual(conversation.activity, .loading)
        XCTAssertEqual(conversation.messages.map(\.text), ["Hello"])
        XCTAssertTrue(conversation.draft.isEmpty)

        stream.continuation.yield("First")
        await waitUntil { conversation.activity == .streaming }
        XCTAssertEqual(conversation.messages.map(\.text), ["Hello", "First"])

        stream.continuation.yield(" and second")
        stream.continuation.finish()
        await waitUntil { conversation.activity == .idle }
        XCTAssertEqual(conversation.messages.map(\.text), ["Hello", "First and second"])
        XCTAssertEqual(conversation.messages.map(\.role), [.user, .assistant])
    }

    func testStoppingKeepsPartialTextAndPreventsLateWrites() async {
        let stream = ResponseStream.makeStream()
        let conversation = GPTConversation(service: Service(responses: ["Start": stream.stream]))
        conversation.draft = "Start"
        conversation.sendDraft()

        stream.continuation.yield("Partial")
        await waitUntil { conversation.activity == .streaming }

        conversation.stop()
        XCTAssertEqual(conversation.activity, .stopped)
        stream.continuation.yield(" late token")
        await waitUntil {
            if case .terminated = stream.continuation.yield(" stale") { return true }
            return false
        }
        XCTAssertEqual(conversation.activity, .stopped)
        XCTAssertEqual(conversation.messages.map(\.text), ["Start", "Partial"])
    }

    func testSendingAgainAndNewChatInvalidateOlderStreams() async {
        let first = ResponseStream.makeStream()
        let second = ResponseStream.makeStream()
        let conversation = GPTConversation(service: Service(responses: [
            "First": first.stream, "Second": second.stream,
        ]))
        conversation.draft = "First"
        conversation.sendDraft()
        first.continuation.yield("Partial")
        await waitUntil { conversation.activity == .streaming }

        conversation.draft = "Second"
        conversation.sendDraft()
        first.continuation.yield(" stale")
        first.continuation.finish()
        second.continuation.yield("Next")
        await waitUntil { conversation.activity == .streaming }
        XCTAssertEqual(conversation.messages.map(\.text), ["First", "Partial", "Second", "Next"])

        let previousID = conversation.conversationID
        conversation.draft = "Draft to clear"
        conversation.newChat()
        second.continuation.yield(" stale")
        second.continuation.finish()

        XCTAssertNotEqual(conversation.conversationID, previousID)
        XCTAssertEqual(conversation.activity, .idle)
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertTrue(conversation.draft.isEmpty)
    }

    func testMockReportsAnErrorAndCanRecover() async {
        let conversation = GPTConversation(service: MockGPTChatService())
        conversation.draft = "simulate error"
        conversation.sendDraft()
        await waitUntil {
            if case .failed = conversation.activity { return true }
            return false
        }

        conversation.draft = "Show me code"
        conversation.sendDraft()
        await waitUntil { conversation.activity == .streaming }
        XCTAssertEqual(conversation.messages.map(\.role), [.user, .user, .assistant])
        conversation.stop()
        XCTAssertEqual(conversation.activity, .stopped)
    }

    func testComposerReturnSendsWhileShiftReturnInsertsNewline() throws {
        let editor = GPTComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        editor.string = "Draft"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        var sends = 0
        editor.onSend = { sends += 1 }

        func returnKey(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            ))
        }

        editor.keyDown(with: try returnKey(.shift))
        XCTAssertEqual(editor.string, "Draft\n")
        XCTAssertEqual(sends, 0)

        editor.keyDown(with: try returnKey([]))
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(editor.string, "Draft\n")
    }

    func testExpandedWindowUsesSharedConversationAndSupportsResizing() throws {
        let controller = GPTChatWindowController.shared
        let window = try XCTUnwrap(controller.window)
        let host = try XCTUnwrap(window.contentView as? NSHostingView<GPTChatView>)
        XCTAssertTrue(host.rootView.conversation === GPTConversation.shared)
        XCTAssertTrue(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
        XCTAssertGreaterThan(window.contentMinSize.width, 0)
        XCTAssertGreaterThan(window.contentMinSize.height, 0)
        XCTAssertFalse(window.isRestorable)
    }

    private typealias ResponseStream = AsyncThrowingStream<String, Error>

    private struct Service: GPTChatService {
        let responses: [String: ResponseStream]

        func response(to messages: [GPTMessage]) -> ResponseStream {
            responses[messages.last?.text ?? ""] ?? ResponseStream { $0.finish() }
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for the conversation state")
    }
}

final class GPTRenderingTests: XCTestCase {
    func testUnfinishedCodeFencePreservesWhitespaceDuringStreaming() {
        let blocks = GPTMarkdownBlock.parse("## Example\n\n~~~swift\n  if ok {\n      print(1)")
        XCTAssertEqual(blocks.map(\.kind), [.heading(2), .code("swift")])
        XCTAssertEqual(blocks.last?.text, "  if ok {\n      print(1)")
    }

    func testTranscriptStopsFollowingOnManualScrollAndResumesAtBottom() {
        let scroll = GPTTranscriptScroll()
        let viewportHeight: CGFloat = 100
        func frame(_ y: CGFloat, height: CGFloat) -> CGRect {
            CGRect(x: 0, y: y, width: 200, height: height)
        }

        XCTAssertFalse(scroll.update(frame: frame(-200, height: 300), viewportHeight: viewportHeight))
        XCTAssertTrue(scroll.update(frame: frame(-200, height: 320), viewportHeight: viewportHeight))
        XCTAssertFalse(scroll.update(frame: frame(-220, height: 320), viewportHeight: viewportHeight))
        XCTAssertTrue(scroll.followsLatest)

        XCTAssertFalse(scroll.update(frame: frame(-140, height: 320), viewportHeight: viewportHeight))
        XCTAssertFalse(scroll.followsLatest)
        XCTAssertFalse(scroll.update(frame: frame(-140, height: 380), viewportHeight: viewportHeight))
        XCTAssertFalse(scroll.followsLatest)

        XCTAssertFalse(scroll.update(frame: frame(-280, height: 380), viewportHeight: viewportHeight))
        XCTAssertTrue(scroll.followsLatest)
    }

    func testTranscriptDoesNotFollowWhileUserScrollsDuringStreamGrowth() {
        let scroll = GPTTranscriptScroll()
        let bottom = CGRect(x: 0, y: -200, width: 200, height: 300)
        XCTAssertFalse(scroll.update(frame: bottom, viewportHeight: 100))

        scroll.isUserScrolling = true
        let updated = CGRect(x: 0, y: -175, width: 200, height: 325)
        XCTAssertFalse(scroll.update(frame: updated, viewportHeight: 100))
        XCTAssertFalse(scroll.followsLatest)

        scroll.isUserScrolling = false
        let larger = CGRect(x: 0, y: -175, width: 200, height: 350)
        XCTAssertFalse(scroll.update(frame: larger, viewportHeight: 100))
    }
}
