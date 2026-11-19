import SwiftUI

struct AskGPTSettingsSection: View {
    @AppStorage(AskGPTPreferences.enabledKey) private var isEnabled = AskGPTPreferences.serviceIsDeclared
    @AppStorage(AskGPTPreferences.languageKey) private var savedLanguage = ""
    @State private var showsLanguages = false

    private var language: AskGPTLanguage { AskGPTPreferences.language(savedLanguage) }

    var body: some View {
        Section("Ask GPT / Selected Text") {
            Toggle("Enable Ask GPT for Selected Text", isOn: $isEnabled)
            LabeledContent("Default Language") {
                Button {
                    showsLanguages = true
                } label: {
                    HStack(spacing: 6) {
                        Text(language.name)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Default Language")
                .accessibilityValue(language.name)
                .popover(isPresented: $showsLanguages) {
                    AskGPTLanguagePicker(defaultLanguage: language) { choice in
                        savedLanguage = choice.rawValue
                        showsLanguages = false
                    }
                }
            }
            if isEnabled {
                VStack(alignment: .leading, spacing: 5) {
                    Text("How to use Ask GPT").font(.subheadline.weight(.semibold))
                    Text("Select text in a compatible app and right-click it. Choose Services → Ask GPT.")
                    Text("If Ask GPT is missing, open System Settings → Keyboard → Keyboard Shortcuts → Services. You can also assign a shortcut there.")
                        .foregroundStyle(.secondary)
                    Button("Open Keyboard Settings", action: openKeyboardSettings)
                }
                .font(.callout)
            }
            Text("This switch controls how NotSoBoringNotch handles requests. macOS controls which items appear in Services.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func openKeyboardSettings() {
        if let keyboard = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"),
           NSWorkspace.shared.open(keyboard) { return }
        if let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.open(settings)
        }
    }
}
