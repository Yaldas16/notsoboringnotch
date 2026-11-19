import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import boringNotch

@MainActor
final class GPTImageAttachmentTests: XCTestCase {
    func testImageValidationAndOrientation() throws {
        let image = try GPTImageAttachment.load(data: fixture(width: 90, height: 30, type: .jpeg, orientation: 6))
        XCTAssertEqual(image.width, 30)
        XCTAssertEqual(image.height, 90)
        XCTAssertEqual(image.mimeType, "image/jpeg")
        XCTAssertTrue(image.dataURL.hasPrefix("data:image/jpeg;base64,"))

        XCTAssertThrowsError(try GPTImageAttachment.load(data: Data("not image data".utf8))) {
            XCTAssertEqual($0 as? GPTImageAttachment.Failure, .unsupported)
        }
        XCTAssertThrowsError(try GPTImageAttachment.load(data: Data(count: GPTImageAttachment.maxSourceBytes + 1))) {
            XCTAssertEqual($0 as? GPTImageAttachment.Failure, .tooLarge)
        }
        XCTAssertThrowsError(try GPTImageAttachment.load(data: fixture(width: 4, height: 4, type: .gif, frames: 2))) {
            XCTAssertEqual($0 as? GPTImageAttachment.Failure, .animated)
        }
    }

    func testLargeImageIsBoundedAndKeepsItsAspectRatio() throws {
        let image = try GPTImageAttachment.load(data: fixture(width: 2_400, height: 1_200))
        XCTAssertEqual(image.width, 2_048)
        XCTAssertEqual(image.height, 1_024)
        XCTAssertEqual(image.preview.width, 320)
        XCTAssertLessThanOrEqual(image.bytes.count, 4 * 1024 * 1024)
    }

    func testImagePasteReadsSupportedDataFromTheInvokedPasteboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let png = try fixture(width: 8, height: 8)
        XCTAssertTrue(board.setString("Text paste remains available", forType: .string))
        XCTAssertNil(GPTImageImport.pasteboardBytes(board))
        XCTAssertTrue(board.setData(png, forType: .png))
        XCTAssertEqual(GPTImageImport.pasteboardBytes(board), png)
    }

    func testImageAndImageOnlyMessagesUseDocumentedResponsesContent() throws {
        let image = try GPTImageAttachment.load(data: fixture(width: 10, height: 8))
        let request = try ChatGPTLiveAPI.responseRequest(
            model: "fixture-model",
            messages: [
                GPTMessage(role: .user, text: "What is this?", images: [image]),
                GPTMessage(role: .assistant, text: "A picture."),
                GPTMessage(role: .user, text: "", images: [image]),
            ],
            token: "fixture-only"
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
        let multimodal = try XCTUnwrap(messages[0]["content"] as? [[String: String]])
        XCTAssertEqual(multimodal.map { $0["type"] }, ["input_text", "input_image"])
        XCTAssertEqual(multimodal[0]["text"], "What is this?")
        XCTAssertEqual(multimodal[1]["image_url"], image.dataURL)
        XCTAssertEqual(multimodal[1]["detail"], "auto")
        XCTAssertEqual(messages[1]["content"] as? String, "A picture.")
        XCTAssertEqual((messages[2]["content"] as? [[String: String]])?.map { $0["type"] }, ["input_image"])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testModelImageRejectionKeepsProviderDiagnostics() {
        let rejected = ChatGPTFailure.remote(
            status: 400, code: "subscription_sharing_unsupported_capability",
            parameter: "input[0].content[1]", requestID: "req_fixture"
        )
        let explained = rejected.explainingImageRejection(ifAttached: true)
        XCTAssertEqual(explained.kind, .imageUnsupported)
        XCTAssertEqual(explained.code, rejected.code)
        XCTAssertEqual(explained.requestID, "req_fixture")
        XCTAssertNotEqual(rejected.explainingImageRejection(ifAttached: false).kind, .imageUnsupported)
        let usage = ChatGPTFailure.remote(status: 429, code: "subscription_sharing_usage_limit_exceeded")
        XCTAssertEqual(usage.explainingImageRejection(ifAttached: true).kind, .usageLimit)
    }

    func testImageOnlyDraftCanSendAndNewChatClearsTheImage() async throws {
        let image = try GPTImageAttachment.load(data: fixture(width: 12, height: 7))
        let conversation = GPTConversation(service: MockGPTChatService())
        XCTAssertFalse(conversation.canStartNewChat)
        conversation.importImages { _ in GPTImageImport(attachments: [image]) }
        XCTAssertTrue(conversation.canStartNewChat, "New Chat can cancel a pending attachment import")
        await waitUntil { !conversation.isImportingImages }
        XCTAssertTrue(conversation.canStartNewChat, "An unsent attachment can be cleared with New Chat")
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertEqual(conversation.draftImages.map(\.id), [image.id])
        XCTAssertTrue(conversation.canSend)
        conversation.sendDraft()
        XCTAssertTrue(conversation.draftImages.isEmpty)
        XCTAssertEqual(conversation.messages.first?.images.map(\.id), [image.id])
        conversation.stop()
        XCTAssertEqual(conversation.activity, .stopped)
        conversation.newChat()
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertTrue(conversation.draftImages.isEmpty)
        XCTAssertFalse(conversation.canStartNewChat)
    }

    func testNewChatDiscardsAnImportThatFinishesAfterCancellation() async throws {
        let image = try GPTImageAttachment.load(data: fixture(width: 9, height: 8))
        let conversation = GPTConversation(service: MockGPTChatService())
        var producer: CheckedContinuation<GPTImageImport, Never>?
        var operationReturned = false
        conversation.importImages { _ in
            let result: GPTImageImport = await withCheckedContinuation { producer = $0 }
            operationReturned = true
            return result
        }
        await waitUntil { producer != nil }
        conversation.newChat()
        try XCTUnwrap(producer).resume(returning: GPTImageImport(attachments: [image]))
        await waitUntil { operationReturned }
        XCTAssertTrue(conversation.draftImages.isEmpty)
        XCTAssertFalse(conversation.isImportingImages)
    }

    func testScreenSelectionAttachesBeforeRevealingChatAndNeverSends() async throws {
        guard #available(macOS 15.2, *) else { return }
        let image = try GPTImageAttachment.load(data: fixture(width: 10, height: 8))
        let conversation = GPTConversation { nil }
        conversation.draft = "Keep my question"
        var revealed = false
        GPTScreenAreaCapture.attach(to: conversation, capture: { GPTImageImport(attachments: [image]) }) { captured in
            XCTAssertTrue(captured)
            XCTAssertEqual(conversation.draftImages.map(\.id), [image.id])
            revealed = true
        }

        await waitUntil { revealed }
        XCTAssertEqual(conversation.draft, "Keep my question")
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertFalse(conversation.canSend)
    }

    func testCancelledScreenSelectionDoesNotRevealChatAndPermissionFailureDoes() async {
        guard #available(macOS 15.2, *) else { return }
        let conversation = GPTConversation { nil }
        var results: [Bool] = []
        GPTScreenAreaCapture.attach(to: conversation, capture: { GPTImageImport() }) { results.append($0) }
        await waitUntil { !conversation.isImportingImages }
        XCTAssertTrue(results.isEmpty)
        XCTAssertNil(conversation.imageFeedback)

        GPTScreenAreaCapture.attach(to: conversation, capture: { GPTImageImport(warning: .capturePermission) }) { results.append($0) }
        await waitUntil { !conversation.isImportingImages }
        XCTAssertEqual(results, [false])
        XCTAssertEqual(conversation.imageFeedback, GPTImageAttachment.Failure.capturePermission.localizedDescription)
        XCTAssertTrue(conversation.draftImages.isEmpty)
    }

    func testRegionConversionHandlesAMonitorAboveAndLeftOfThePrimaryDisplay() {
        guard #available(macOS 15.2, *) else { return }
        let display = CGRect(x: -1_200, y: -900, width: 1_200, height: 900)
        let selected = CGRect(x: 80, y: 710, width: 250, height: 120)
        XCTAssertEqual(GPTScreenAreaCapture.quartzRect(from: selected, display: display),
                       CGRect(x: -1_120, y: -830, width: 250, height: 120))
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate())
    }

    private func fixture(width: Int, height: Int, type: UTType = .png, orientation: Int = 1, frames: Int = 1) throws -> Data {
        let color = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: 0, space: color,
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, type.identifier as CFString, frames, nil))
        for _ in 0..<frames {
            CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return bytes as Data
    }
}
