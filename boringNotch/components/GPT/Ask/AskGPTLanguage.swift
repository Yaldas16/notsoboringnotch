import Foundation

enum AskGPTLanguage: String, CaseIterable, Identifiable {
    case tr, en, de, fr, es, it, pt, ru, ar, ja, ko, zh, nl

    var id: String { rawValue }

    var name: String { name(in: .current) }
    private var nativeName: String { name(in: Locale(identifier: rawValue)) }

    private func name(in locale: Locale) -> String {
        locale.localizedString(forLanguageCode: rawValue) ?? rawValue
    }

    static func preferred(from identifiers: [String] = Locale.preferredLanguages) -> Self {
        identifiers.lazy.compactMap {
            Locale(identifier: $0).language.languageCode.flatMap { Self(rawValue: $0.identifier) }
        }.first ?? .en
    }

    static func search(_ query: String, defaultLanguage: Self) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let others = allCases.filter { $0 != defaultLanguage }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ([defaultLanguage] + others).filter { language in
            let names = [language.name, language.nativeName, language.name(in: Locale(identifier: "en")), language.rawValue]
            return terms.allSatisfy { term in
                names.contains { $0.localizedStandardContains(String(term)) }
            }
        }
    }

    func question(for action: AskGPTDraft.Suggestion, target: Self? = nil) -> String {
        let prompts = prompts
        switch action {
        case .explain: return prompts.explain
        case .summarize: return prompts.summarize
        case .rewrite: return prompts.rewrite
        case .translate:
            guard let target else { return prompts.translate }
            return String(format: prompts.translation, target.name(in: Locale(identifier: rawValue)))
        }
    }

    private var prompts: (explain: String, summarize: String, rewrite: String, translate: String, translation: String) {
        switch self {
        case .tr: ("Bunu açıkla", "Bunu özetle", "Bunu yeniden yaz", "Bunu çevir", "Bu metni şu dile çevir: %@.")
        case .en: ("Explain this", "Summarize this", "Rewrite this", "Translate this", "Translate this text into %@.")
        case .de: ("Erkläre das", "Fasse das zusammen", "Formuliere das um", "Übersetze das", "Übersetze diesen Text ins %@.")
        case .fr: ("Explique ceci", "Résume ceci", "Reformule ceci", "Traduis ceci", "Traduis ce texte en %@.")
        case .es: ("Explica esto", "Resume esto", "Reescribe esto", "Traduce esto", "Traduce este texto al %@.")
        case .it: ("Spiega questo", "Riassumi questo", "Riscrivi questo", "Traduci questo", "Traduci questo testo in %@.")
        case .pt: ("Explique isto", "Resuma isto", "Reescreva isto", "Traduza isto", "Traduza este texto para %@.")
        case .ru: ("Объясни это", "Кратко изложи это", "Перефразируй это", "Переведи это", "Переведи этот текст. Язык перевода: %@.")
        case .ar: ("اشرح هذا", "لخّص هذا", "أعد صياغة هذا", "ترجم هذا", "ترجم هذا النص إلى اللغة التالية: %@.")
        case .ja: ("これを説明して", "これを要約して", "これを書き直して", "これを翻訳して", "この文章を%@に翻訳してください。")
        case .ko: ("이것을 설명해 줘", "이것을 요약해 줘", "이것을 다시 써 줘", "이것을 번역해 줘", "이 글을 다음 언어로 번역해 주세요: %@.")
        case .zh: ("解释这段文字", "总结这段文字", "改写这段文字", "翻译这段文字", "请将这段文字翻译成%@。")
        case .nl: ("Leg dit uit", "Vat dit samen", "Herschrijf dit", "Vertaal dit", "Vertaal deze tekst naar het %@.")
        }
    }
}

enum AskGPTPreferences {
    static let enabledKey = "askGPTSelectedTextEnabled"
    static let languageKey = "askGPTDefaultLanguage"

    static var serviceIsDeclared: Bool {
        let services = Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]]
        return services?.contains { $0["NSMessage"] as? String == "askGPT" } == true
    }

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? serviceIsDeclared
    }

    static func language(_ saved: String) -> AskGPTLanguage {
        AskGPTLanguage(rawValue: saved) ?? .preferred()
    }
}
