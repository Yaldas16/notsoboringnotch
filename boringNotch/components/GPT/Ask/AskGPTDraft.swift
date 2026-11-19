import Foundation
import Observation

@MainActor
@Observable
final class AskGPTDraft {
    enum Suggestion: String, CaseIterable {
        case explain = "Explain"
        case summarize = "Summarize"
        case translate = "Translate"
        case rewrite = "Rewrite"

        var question: String { AskGPTLanguage.en.question(for: self, target: self == .translate ? .en : nil) }
    }

    static let selectionLimit = 64 * 1024
    static let questionLimit = 8 * 1024

    let selection: String
    let oversizedSelection: Bool
    let preview: String
    let canExpand: Bool
    var question = ""

    init(selection: String) {
        self.selection = selection
        oversizedSelection = selection.utf8.count > Self.selectionLimit
        let prefix = selection.prefix(600)
        preview = prefix.endIndex == selection.endIndex ? selection : String(prefix) + "…"
        canExpand = !oversizedSelection && (prefix.count > 120 || prefix.filter { $0.isNewline }.count >= 3)
    }

    var warning: String? {
        if oversizedSelection {
            return String(localized: "This selection exceeds 64 KB. Cancel and select a shorter passage.")
        }
        if question.utf8.count > Self.questionLimit {
            return String(localized: "The question exceeds 8 KB. Shorten it to continue.")
        }
        return nil
    }

    var canSubmit: Bool {
        warning == nil && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var prompt: String? {
        guard canSubmit else { return nil }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Question:\n\(question)\n\nSelected text:\n\(selection)"
    }

    func apply(_ suggestion: Suggestion, language: AskGPTLanguage = .en, target: AskGPTLanguage? = nil) {
        question = language.question(for: suggestion, target: suggestion == .translate ? target ?? language : nil)
    }
}
