import SwiftUI

struct GPTMarkdownBlock: Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case listItem(String)
        case quote
        case code(String?)
        case divider
    }

    let kind: Kind
    let text: String

    static func parse(_ markdown: String) -> [Self] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Self] = []
        var paragraph: [String] = []
        var index = 0

        func finishParagraph() {
            if !paragraph.isEmpty {
                blocks.append(Self(kind: .paragraph, text: paragraph.joined(separator: "\n")))
                paragraph.removeAll(keepingCapacity: true)
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1

            if let fence = Fence(trimmed) {
                finishParagraph()
                var code: [String] = []
                while index < lines.count {
                    let codeLine = lines[index]
                    index += 1
                    let candidate = Fence(codeLine.trimmingCharacters(in: .whitespaces))
                    if let candidate, candidate.marker == fence.marker,
                       candidate.count >= fence.count, candidate.info.isEmpty {
                        break
                    }
                    code.append(codeLine)
                }
                blocks.append(Self(kind: .code(fence.info.split(whereSeparator: \.isWhitespace).first.map(String.init)),
                                   text: code.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                finishParagraph()
            } else if let block = singleLineBlock(trimmed) {
                finishParagraph()
                blocks.append(block)
            } else {
                paragraph.append(line)
            }
        }
        finishParagraph()
        return blocks
    }

    private static func singleLineBlock(_ line: String) -> Self? {
        let heading = line.prefix(while: { $0 == "#" }).count
        if (1...6).contains(heading), line.dropFirst(heading).first == " " {
            return Self(kind: .heading(heading), text: String(line.dropFirst(heading + 1)))
        }
        let divider = line.filter { !$0.isWhitespace }
        if divider.count >= 3, let marker = divider.first, "-*_".contains(marker),
           divider.allSatisfy({ $0 == marker }) {
            return Self(kind: .divider, text: "")
        }
        if let marker = line.first, "-+*".contains(marker), line.dropFirst().first == " " {
            return Self(kind: .listItem("•"), text: String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: \.isNumber)
        let afterDigits = line.dropFirst(digits.count)
        if !digits.isEmpty, afterDigits.hasPrefix(". ") || afterDigits.hasPrefix(") ") {
            return Self(kind: .listItem("\(digits)."), text: String(afterDigits.dropFirst(2)))
        }
        if line.hasPrefix(">") {
            return Self(kind: .quote, text: String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private struct Fence {
        let marker: Character
        let count: Int
        let info: String

        init?(_ line: String) {
            guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
            let count = line.prefix(while: { $0 == marker }).count
            guard count >= 3 else { return nil }
            self.marker = marker
            self.count = count
            self.info = String(line.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        }
    }
}

struct GPTMarkdownView: View, Equatable {
    let source: String

    var body: some View {
        let blocks = GPTMarkdownBlock.parse(source)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(blocks.indices, id: \.self) { index in
                render(blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func render(_ block: GPTMarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            inline(block.text)
        case .heading(let level):
            inline(block.text)
                .font(level < 3 ? .headline : .subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(verbatim: marker)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                inline(block.text)
            }
        case .quote:
            HStack(spacing: 8) {
                inline(block.text)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
            .overlay(alignment: .leading) { Capsule().fill(.quaternary).frame(width: 2) }
        case .code(let language):
            GPTCodeBlock(language: language, code: block.text)
        case .divider:
            Divider()
        }
    }

    private func inline(_ source: String) -> some View {
        let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        return Text(attributed ?? AttributedString(source))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct GPTCodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? String(localized: "Code"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "document.on.document")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy code")
                .disabled(code.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1) }
        .onChange(of: code) { copied = false }
    }
}
