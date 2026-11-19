import SwiftUI

struct AskGPTLanguagePicker: View {
    let defaultLanguage: AskGPTLanguage
    let choose: (AskGPTLanguage) -> Void

    @State private var query = ""
    @State private var selection: AskGPTLanguage?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var results: [AskGPTLanguage] { AskGPTLanguage.search(query, defaultLanguage: defaultLanguage) }

    var body: some View {
        VStack(spacing: 6) {
            TextField("Search languages", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onMoveCommand(perform: move)
                .onSubmit { if let language = selection ?? results.first { choose(language) } }
                .padding([.horizontal, .top], 8)

            if results.isEmpty {
                Text("No matching languages").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    List(selection: $selection) {
                        ForEach(results) { language in
                            Button { choose(language) } label: {
                                HStack {
                                    Text(language.name)
                                    if language == defaultLanguage {
                                        Text("(Default)").foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .tag(language)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: selection) { _, language in
                        if let language { scroll.scrollTo(language) }
                    }
                    .onKeyPress(.return) {
                        guard let selection else { return .ignored }
                        choose(selection)
                        return .handled
                    }
                }
            }
        }
        .frame(width: 255, height: 240)
        .onAppear {
            selection = results.first
            searchFocused = true
        }
        .onChange(of: query) { _, _ in selection = results.first }
        .onExitCommand { dismiss() }
    }

    private func move(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down, !results.isEmpty else { return }
        guard let selection, let index = results.firstIndex(of: selection) else {
            selection = results.first
            return
        }
        let offset = direction == .up ? -1 : 1
        self.selection = results[min(max(index + offset, 0), results.count - 1)]
    }
}
