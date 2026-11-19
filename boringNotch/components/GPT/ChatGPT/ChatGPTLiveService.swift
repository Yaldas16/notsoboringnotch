import Foundation

struct ChatGPTModel: Identifiable, Equatable, Sendable {
    let slug: String
    let displayName: String
    var id: String { slug }
}

struct ChatGPTLiveAPI: Sendable {
    let http: ChatGPTHTTP
    let sessions: ChatGPTSessions

    func models(for clientID: String) async throws -> [ChatGPTModel] {
        try await withAccess(for: clientID) { token in
            var request = URLRequest(url: ChatGPTEndpoints.models)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let secrets = [token]
            let (data, response) = try await http.load(request, secrets: secrets, stage: .models)
            let trace = ChatGPTRequestTrace(.modelDecoding, response, secrets: secrets)
            do {
                if let failure = ChatGPTFailure.serviceError(data, status: response.statusCode,
                                                             requestID: response.requestID, secrets: secrets) {
                    throw failure
                }
                let models = try Self.decodeModels(data)
                trace.record("ChatGPT plan catalog decoded")
                return models
            } catch let failure as ChatGPTFailure {
                trace.record("Model catalog failed", failure: failure)
                throw trace.attach(failure)
            }
        }
    }

    static func decodeModels(_ data: Data) throws -> [ChatGPTModel] {
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            throw ChatGPTFailure(kind: .invalidResponse, protocolIssue: .invalidCatalog)
        }
        guard let entries = catalog.models else {
            throw ChatGPTFailure(kind: .invalidResponse, protocolIssue: catalog.ordinaryList ? .ordinaryCatalog : .invalidCatalog)
        }
        var seen: Set<String> = []
        let models: [ChatGPTModel] = entries.compactMap { entry in
            guard entry.visibility == "list", let slug = entry.slug, !slug.isEmpty,
                  let displayName = entry.displayName, !displayName.isEmpty, seen.insert(slug).inserted
            else { return nil }
            return ChatGPTModel(slug: slug, displayName: displayName)
        }
        guard !models.isEmpty else { throw ChatGPTFailure(kind: .modelUnavailable, protocolIssue: .noVisibleModels) }
        return models
    }

    func stream(for clientID: String, model: String, messages: [GPTMessage],
                continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        try await withAccess(for: clientID) { token in
            let request = try Self.responseRequest(model: model, messages: messages, token: token)
            do {
                try await readStream(request, token: token, continuation: continuation)
            } catch let failure as ChatGPTFailure {
                throw failure.explainingImageRejection(ifAttached: messages.contains { !$0.images.isEmpty })
            }
        }
    }

    static func responseRequest(model: String, messages: [GPTMessage], token: String) throws -> URLRequest {
        var request = URLRequest(url: ChatGPTEndpoints.responses)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Body(
            model: model, input: messages.map { Body.Message(message: $0) }
        ))
        return request
    }

    private func withAccess<T>(for clientID: String, operation: (String) async throws -> T) async throws -> T {
        let token = try await sessions.access(for: clientID)
        try Task.checkCancellation()
        do {
            return try await operation(token)
        } catch let failure as ChatGPTFailure where failure.status == 401 {
            // Only a 401 before an inference stream opens can trigger a retry.
            let renewal: String
            do {
                renewal = try await sessions.access(for: clientID, replacing: token)
            } catch let blocked as ChatGPTFailure where blocked.kind == .credential && blocked.code == nil && blocked.trace == nil {
                // A refresh can be unavailable before the provider permits renewals. Keep the original HTTP failure.
                throw failure
            }
            try Task.checkCancellation()
            return try await operation(renewal)
        }
    }

    private func readStream(_ request: URLRequest, token: String,
                            continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let secrets = [token]
        var trace = ChatGPTRequestTrace(.submission)
        do {
            let (bytes, rawResponse) = try await http.session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = rawResponse as? HTTPURLResponse else {
                throw ChatGPTFailure(kind: .invalidResponse, protocolIssue: .nonHTTP)
            }
            trace = ChatGPTRequestTrace(.submission, response, secrets: secrets)
            trace.record("HTTP response received")
            var body = bytes.makeAsyncIterator()
            guard response.statusCode == 200 else {
                let errorBody = try await Self.readErrorBody(&body, prefix: [])
                throw ChatGPTFailure.response(response, data: errorBody, secrets: secrets)
            }

            var prefix: [UInt8] = []
            if trace.contentType != "text/event-stream" {
                var probe = ChatGPTSSEProbe()
                var framing: ChatGPTSSEProbe.Framing = .pending
                while framing == .pending, let byte = try await body.next() {
                    try Task.checkCancellation()
                    framing = probe.append(byte)
                }
                guard framing == .eventStream else {
                    let errorBody = try await Self.readErrorBody(&body, prefix: probe.prefix)
                    throw ChatGPTFailure.serviceError(errorBody, status: response.statusCode,
                                                     requestID: trace.requestID, secrets: secrets)
                        ?? ChatGPTFailure(kind: .invalidResponse, protocolIssue: .wrongContentType)
                }
                prefix = probe.prefix
            }

            trace = ChatGPTRequestTrace(.stream, copying: trace)
            if !prefix.isEmpty { trace.record("Recognized SSE framing without a usable Content-Type") }
            var parser = ChatGPTSSEParser()
            var stream = ChatGPTResponseStream()
            // The probe stops at the first field marker, before it can contain a complete event.
            for byte in prefix { _ = try parser.append(byte) }
            while let byte = try await body.next() {
                try Task.checkCancellation()
                guard let payload = try parser.append(byte) else { continue }
                switch try stream.consume(payload, requestID: trace.requestID, token: token) {
                case .text(let text):
                    if case .terminated = continuation.yield(text) { throw CancellationError() }
                case .completed:
                    trace.record("Server confirmed completion", end: .completed)
                    return
                case .ignored: break
                }
            }
            try stream.finish(requestID: trace.requestID)
        } catch {
            if Task.isCancelled || error is CancellationError {
                trace.record("Generation cancelled", end: .cancelled)
                throw CancellationError()
            }
            let failure = error as? ChatGPTFailure ?? ChatGPTFailure(kind: .network)
            let termination: ChatGPTStreamEnd = if trace.stage == .submission {
                .notOpened
            } else if let end = failure.streamEnd {
                end
            } else {
                failure.kind == .network ? .network : .malformed
            }
            trace.record("Response failed", failure: failure, end: termination)
            throw trace.attach(failure)
        }
    }

    private static func readErrorBody(_ bytes: inout URLSession.AsyncBytes.Iterator, prefix: [UInt8]) async throws -> Data {
        var body = Data(prefix)
        do {
            while body.count < 65_536, let byte = try await bytes.next() {
                body.append(byte)
            }
        } catch {
            // The received status and request ID are useful even when the error body was interrupted.
            try Task.checkCancellation()
        }
        return body
    }

    private struct Catalog: Decodable {
        let models: [Entry]?
        let ordinaryList: Bool

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Keys.self)
            models = try? fields.decode([Entry].self, forKey: .models)
            ordinaryList = !fields.contains(.models) && (try? fields.nestedUnkeyedContainer(forKey: .data)) != nil
        }

        private enum Keys: String, CodingKey { case models, data }

        struct Entry: Decodable {
            let slug: String?
            let displayName: String?
            let visibility: String?

            init(from decoder: Decoder) {
                let fields = try? decoder.container(keyedBy: CodingKeys.self)
                slug = try? fields?.decode(String.self, forKey: .slug)
                displayName = try? fields?.decode(String.self, forKey: .displayName)
                visibility = try? fields?.decode(String.self, forKey: .visibility)
            }

            private enum CodingKeys: String, CodingKey {
                case slug, visibility
                case displayName = "display_name"
            }
        }
    }

    private struct Body: Encodable {
        let model: String
        let input: [Message]
        let store = false
        let stream = true

        struct Message: Encodable {
            let message: GPTMessage

            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: Keys.self)
                try values.encode(message.role == .user ? "user" : "assistant", forKey: .role)
                if message.images.isEmpty {
                    try values.encode(message.text, forKey: .content)
                    return
                }
                var parts = values.nestedUnkeyedContainer(forKey: .content)
                if !message.text.isEmpty {
                    var text = parts.nestedContainer(keyedBy: Keys.self)
                    try text.encode("input_text", forKey: .type)
                    try text.encode(message.text, forKey: .text)
                }
                for image in message.images {
                    var part = parts.nestedContainer(keyedBy: Keys.self)
                    try part.encode("input_image", forKey: .type)
                    try part.encode(image.dataURL, forKey: .imageURL)
                    try part.encode("auto", forKey: .detail)
                }
            }

            private enum Keys: String, CodingKey {
                case role, content, type, text, detail
                case imageURL = "image_url"
            }
        }
    }
}

struct ChatGPTLiveService: GPTChatService {
    let api: ChatGPTLiveAPI
    let clientID: String
    let model: String
    let onFailure: @Sendable (ChatGPTFailure) async -> Void

    func response(to messages: [GPTMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await api.stream(for: clientID, model: model, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    if !Task.isCancelled, let failure = error as? ChatGPTFailure {
                        await onFailure(failure)
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}
