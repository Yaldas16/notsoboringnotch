import SwiftUI

struct GPTConnectButton: View {
    let account: GPTAccountController

    var body: some View {
        if account.canRetryRestore {
            Button("Retry Keychain Access", action: account.retryRestore)
        } else if account.operation == .connecting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finish sign-in in your browser")
                    .foregroundStyle(.secondary)
                Button("Cancel", action: account.cancelSignIn)
            }
        } else {
            Button {
                let needsConsent = (account.active?.permitsInference == false && account.active?.connected == true)
                    || account.restriction?.kind == .consent
                account.connect(clientID: account.activeID, requestConsent: needsConsent)
            } label: {
                Text("Continue with ChatGPT")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .foregroundStyle(.white)
                    .background(.black, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.35)) }
            }
            .buttonStyle(.plain)
            .disabled(account.operation != nil)
        }
    }
}

struct GPTModelPicker: View {
    let account: GPTAccountController

    var body: some View {
        Picker("Model", selection: Binding(get: { account.selectedModelID }, set: { account.selectModel($0) })) {
            if account.selectedModelID == nil {
                Text("Choose a model").tag(String?.none)
            }
            ForEach(account.models) { model in
                Text(model.displayName).tag(Optional(model.slug))
            }
        }
        .pickerStyle(.menu)
        .disabled(account.operation != nil)
    }
}

struct GPTAccountSettingsView: View {
    private let account = GPTAccountController.shared

    var body: some View {
        Form {
            Section("ChatGPT Account") {
                if let active = account.active {
                    LabeledContent("Account", value: active.label)
                    LabeledContent("Status", value: connectionStatus(active))
                } else {
                    Text("Use your ChatGPT plan for eligible AI requests in NotSoBoringNotch.")
                        .foregroundStyle(.secondary)
                }

                if account.active?.connected == true && account.active?.permitsInference == true
                    && account.operation != .connecting {
                    HStack {
                        Button("Reconnect") { account.connect(clientID: account.activeID) }
                        Button("Sign Out", role: .destructive, action: account.signOut)
                    }
                    .disabled(account.operation != nil)
                } else {
                    GPTConnectButton(account: account)
                    if account.active?.connected == true && account.operation != .connecting {
                        Button("Sign Out", role: .destructive, action: account.signOut)
                            .disabled(account.operation != nil)
                    }
                }

                if !account.accounts.isEmpty {
                    Menu("Saved accounts") {
                        ForEach(account.accounts) { saved in
                            Button(saved.label) { account.connect(clientID: saved.id) }
                        }
                        Divider()
                        Button("Add ChatGPT account or workspace…") { account.connect(clientID: nil) }
                    }
                    .disabled(account.operation != nil)
                }

                if let issue = account.issue ?? account.restriction {
                    Text(issue.localizedDescription).foregroundStyle(.secondary)
                }
                if account.revocationUnconfirmed {
                    Text("You signed out locally. ChatGPT did not confirm revocation. You can disconnect the app in ChatGPT settings.")
                        .foregroundStyle(.secondary)
                }
            }

            if account.active?.permitsInference == true {
                Section("Model") {
                    if !account.models.isEmpty { GPTModelPicker(account: account) }
                    Button("Refresh Models", action: account.refreshModels)
                        .disabled(account.operation != nil)
                }
            }
            AskGPTSettingsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("GPT")
        .task { account.prepare() }
    }

    private func connectionStatus(_ active: ChatGPTAccountSummary) -> String {
        if account.operation == .signingOut { return "Signing out…" }
        if !active.connected { return "Signed out" }
        if account.restriction?.kind == .credential { return "Reconnect required" }
        if !active.permitsInference || account.restriction?.kind == .consent { return "ChatGPT plan usage disabled" }
        if account.restriction?.kind == .ineligible { return "ChatGPT plan usage unavailable" }
        return "Connected"
    }
}
