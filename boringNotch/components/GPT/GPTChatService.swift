import Foundation

struct GPTMessage: Identifiable, Equatable, Sendable {
    enum Role: Sendable {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    var images: [GPTImageAttachment] = []
}

protocol GPTChatService: Sendable {
    func response(to messages: [GPTMessage]) -> AsyncThrowingStream<String, Error>
}

struct MockGPTChatService: GPTChatService {
    enum MockError: LocalizedError {
        case simulated

        var errorDescription: String? {
            String(localized: "The mock response failed. Send another message to try again.")
        }
    }

    func response(to messages: [GPTMessage]) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.last?.text.lowercased() ?? ""
        let response = Self.reply(for: prompt)
        let words = response.split(separator: " ", omittingEmptySubsequences: false)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await Task.sleep(for: .milliseconds(400))
                    if prompt == "simulate error" { throw MockError.simulated }

                    for (index, word) in words.enumerated() {
                        try await Task.sleep(for: .milliseconds(32))
                        let chunk = index == 0 ? String(word) : " " + word
                        if case .terminated = continuation.yield(chunk) { return }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private static func reply(for prompt: String) -> String {
        let markdown = """
        ## Markdown preview

        This is a **simulated response**. The chat can display *emphasis*, [links](https://www.apple.com/macos/), and `inline code`.

        - Follow the response as it streams.
        - Scroll up to read earlier messages.

        > This conversation lives in memory for this session.
        """
        let code = """
        ## Swift example

        This example is part of the local mock.

        ```swift
        func greeting(for name: String) -> String {
            "Hello, \\(name)!"
        }

        let message = greeting(for: "NotSoBoringNotch")
        print(message)
        ```

        Use **Copy** above the code to put the snippet on your clipboard.
        """
        if prompt.contains("long") {
            return (1...9).map { section in
                """
                ### Section \(section)

                This longer mock response is designed for testing scroll behavior. Read an earlier section while the text streams, or jump to the latest message when you're ready.
                """
            }.joined(separator: "\n\n")
        }
        if prompt.contains("code") { return code }
        return markdown
    }
}
