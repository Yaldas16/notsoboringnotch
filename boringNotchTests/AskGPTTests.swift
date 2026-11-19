import AppKit
import XCTest
@testable import boringNotch

@MainActor
final class AskGPTTests: XCTestCase {
    func testServiceReceivesSelectionWithoutChangingWhitespaceOrPastingIntoChat() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let selection = "  Photosynthesis converts light into chemical energy.\n"
        XCTAssertTrue(board.setString(selection, forType: .string))
        var received: String?
        let provider = AskGPTService(isEnabled: { true }) { received = $0 }
        var error: NSString?

        provider.askGPT(board, userData: nil, error: &error)

        XCTAssertNil(error)
        XCTAssertEqual(received, selection)
        XCTAssertEqual(board.string(forType: .string), selection)
        let services = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]])
        let service = try XCTUnwrap(services.first { $0["NSMessage"] as? String == "askGPT" })
        XCTAssertEqual(service["NSPortName"] as? String, "NotSoBoringNotch")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.yusuf.boringnotch.personal")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "NotSoBoringNotch")
        XCTAssertTrue(NSApp.servicesProvider is AskGPTService)
    }

    func testNativeTextViewWritesOnlyItsSelectedRangeToTheServicesPasteboard() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 250, height: 90))
        textView.string = "Before selected text after"
        textView.setSelectedRange(NSRange(location: 7, length: 13))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(textView.writeSelection(to: board, types: textView.writablePasteboardTypes))
        XCTAssertEqual(AskGPTServiceInput.selectedText(from: board), "selected text")
    }

    func testRichTextProvidesPlainSelectionAndEmptyInputDoesNotPresent() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let attributed = NSAttributedString(string: "Styled text", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        XCTAssertTrue(board.setData(rtf, forType: .rtf))
        XCTAssertEqual(AskGPTServiceInput.selectedText(from: board), "Styled text")

        board.clearContents()
        XCTAssertTrue(board.setString(" \n\t ", forType: .string))
        let provider = AskGPTService(isEnabled: { true }) { _ in XCTFail("Whitespace selection opened a composer") }
        var error: NSString?
        provider.askGPT(board, userData: nil, error: &error)
        XCTAssertNotNil(error)
    }

    func testSuggestionsPopulateEditableQuestionsWithoutChangingSelection() {
        let draft = AskGPTDraft(selection: "Özgün metin\n")
        for suggestion in AskGPTDraft.Suggestion.allCases {
            draft.apply(suggestion)
            XCTAssertEqual(draft.question, suggestion.question)
            XCTAssertEqual(draft.selection, "Özgün metin\n")
        }
        draft.question = "Explain this for beginners."
        XCTAssertEqual(draft.prompt, "Question:\nExplain this for beginners.\n\nSelected text:\nÖzgün metin\n")
    }

    func testOversizedSelectionIsRetainedButCannotBeSent() {
        let original = String(repeating: "é", count: AskGPTDraft.selectionLimit)
        let draft = AskGPTDraft(selection: original)
        draft.apply(.summarize)
        XCTAssertEqual(draft.selection, original)
        XCTAssertNotNil(draft.warning)
        XCTAssertNil(draft.prompt)
    }

    func testPendingQuestionSurvivesDisconnectedStateAndDoesNotReplaceChatDraft() throws {
        var connected = false
        let conversation = GPTConversation { connected ? MockGPTChatService() : nil }
        conversation.draft = "Unrelated chat draft"
        let request = AskGPTDraft(selection: "  Original selected text\n")
        request.question = "Describe this."
        let prompt = try XCTUnwrap(request.prompt)

        XCTAssertFalse(conversation.submit(prompt))
        XCTAssertEqual(request.question, "Describe this.")
        XCTAssertTrue(conversation.messages.isEmpty)
        connected = true
        XCTAssertTrue(conversation.messages.isEmpty, "Connecting must not submit the pending selection")
        XCTAssertTrue(conversation.submit(prompt))
        XCTAssertEqual(conversation.messages.last?.text, prompt)
        XCTAssertEqual(conversation.draft, "Unrelated chat draft")
        conversation.stop()
        XCTAssertEqual(conversation.activity, .stopped)
        conversation.newChat()
        XCTAssertTrue(conversation.messages.isEmpty)
    }
    func testSelectedTextSettingBlocksServiceHandlingUntilEnabled() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("Original selection", forType: .string))
        var enabled = false
        var received: [String] = []
        let provider = AskGPTService(isEnabled: { enabled }) { received.append($0) }

        var error: NSString?
        provider.askGPT(board, userData: nil, error: &error)
        XCTAssertNotNil(error)
        XCTAssertTrue(received.isEmpty)

        enabled = true
        error = nil
        provider.askGPT(board, userData: nil, error: &error)
        XCTAssertNil(error)
        XCTAssertEqual(received, ["Original selection"])
    }

    func testColdLaunchAndRepeatedInvocationsKeepDistinctSelectionsWithTheirQuestions() throws {
        var requests = AskGPTRequests()
        requests.enqueue(" First selection\n", on: nil)
        requests.enqueue("Second selection", on: nil)
        requests.enqueue(" First selection\n", on: nil)
        XCTAssertTrue(requests.hasRequests)
        XCTAssertNil(requests.presentNext())

        requests.markReady()
        let first = try XCTUnwrap(requests.presentNext()).draft
        first.question = "First custom question"
        requests.enqueue(first.selection, on: nil)
        requests.enqueue("Second selection", on: nil)
        XCTAssertNil(requests.presentNext())
        XCTAssertEqual(requests.current?.draft.question, "First custom question")
        XCTAssertEqual(requests.current?.draft.selection, " First selection\n")

        requests.finish()
        let second = try XCTUnwrap(requests.presentNext()).draft
        XCTAssertEqual(second.selection, "Second selection")
        XCTAssertTrue(second.question.isEmpty)
        requests.finish()
        XCTAssertFalse(requests.hasRequests)
        XCTAssertNil(requests.presentNext())
    }

    func testComposerWindowAcceptsAnEditorAttachedAfterTheFocusRequest() {
        let window = GPTComposerWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
                                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.focusComposerWhenReady()
        XCTAssertNil(window.initialFirstResponder)

        let editor = GPTComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        window.contentView?.addSubview(editor)
        XCTAssertIdentical(window.initialFirstResponder, editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertIdentical(window.firstResponder, editor)

        window.clearComposerFocus()
        XCTAssertNil(window.initialFirstResponder)
    }

    func testLanguageSearchShowsTheDefaultFirstAndMatchesNamesAndEndonyms() {
        XCTAssertEqual(AskGPTLanguage.preferred(from: ["tr-TR", "en-US"]), .tr)
        XCTAssertEqual(AskGPTLanguage.preferred(from: ["pl-PL", "de-DE"]), .de)
        XCTAssertEqual(AskGPTLanguage.preferred(from: ["pl-PL"]), .en)
        XCTAssertEqual(AskGPTLanguage.search("", defaultLanguage: .tr).first, .tr)
        XCTAssertEqual(AskGPTLanguage.search("turk", defaultLanguage: .en), [.tr])
        XCTAssertEqual(AskGPTLanguage.search("Deutsch", defaultLanguage: .tr), [.de])
        XCTAssertEqual(AskGPTLanguage.search("日本語", defaultLanguage: .tr), [.ja])
        XCTAssertEqual(AskGPTLanguage.search("unmatched", defaultLanguage: .tr), [])
    }

    func testTurkishQuickActionsAndOneTimeTranslationsAreEditableAndPreserveSelection() {
        let draft = AskGPTDraft(selection: "  Metin\n")
        for (action, text) in [(AskGPTDraft.Suggestion.explain, "Bunu açıkla"),
                               (.summarize, "Bunu özetle"), (.rewrite, "Bunu yeniden yaz")] {
            draft.apply(action, language: .tr)
            XCTAssertEqual(draft.question, text)
        }
        XCTAssertEqual(AskGPTLanguage.tr.question(for: .translate), "Bunu çevir")
        draft.apply(.translate, language: .tr, target: .de)
        XCTAssertEqual(draft.question, "Bu metni şu dile çevir: Almanca.")
        draft.apply(.translate, language: .en, target: .tr)
        XCTAssertEqual(draft.question, "Translate this text into Turkish.")
        draft.question += " Preserve line breaks."
        XCTAssertTrue(draft.canSubmit)
        XCTAssertEqual(draft.selection, "  Metin\n")
    }

    func testEverySupportedLanguageHasDistinctLocalizedQuickActionsAndATranslationPrompt() {
        for language in AskGPTLanguage.allCases {
            let questions = AskGPTDraft.Suggestion.allCases.map { language.question(for: $0) }
            XCTAssertEqual(Set(questions).count, 4)
            if language != .en {
                XCTAssertNotEqual(questions, AskGPTDraft.Suggestion.allCases.map { AskGPTLanguage.en.question(for: $0) })
            }
            for target in AskGPTLanguage.allCases {
                let question = language.question(for: .translate, target: target)
                XCTAssertFalse(question.contains("%@"))
                XCTAssertNotEqual(question, language.question(for: .translate))
            }
        }
    }

}
