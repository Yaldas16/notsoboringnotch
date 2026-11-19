import Foundation

struct ChatGPTSSEProbe {
    enum Framing { case pending, eventStream, other }

    private static let bom: [UInt8] = [239, 187, 191]
    private static let markers = ["data:", "event:", "id:", "retry:", ":"].map { Array($0.utf8) }
    private(set) var prefix: [UInt8] = []

    // Some HTTP 200 responses reach the client without a usable Content-Type.
    // Look only at a bounded prefix, then replay it through the normal SSE parser.
    mutating func append(_ byte: UInt8) -> Framing {
        prefix.append(byte)
        let bytes: ArraySlice<UInt8>
        if prefix.starts(with: Self.bom) {
            bytes = prefix.dropFirst(Self.bom.count)
        } else if Self.bom.starts(with: prefix) {
            return .pending
        } else {
            bytes = prefix[...]
        }

        let candidate = bytes.drop(while: { $0 == 13 || $0 == 10 || $0 == 32 || $0 == 9 })
        if Self.markers.contains(where: { candidate.starts(with: $0) }) { return .eventStream }
        if prefix.count < 4_096, Self.markers.contains(where: { $0.starts(with: candidate) }) { return .pending }
        return .other
    }
}

struct ChatGPTSSEParser {
    private static let eventLimit = 4 * 1024 * 1024
    private var line: [UInt8] = []
    private var data = Data()
    private var firstLine = true
    private var skipLineFeed = false

    // SSE framing is byte-oriented. Decoding only after a full line preserves split UTF-8 characters.
    mutating func append(_ byte: UInt8) throws -> Data? {
        if skipLineFeed {
            skipLineFeed = false
            if byte == 10 { return nil }
        }
        if byte == 13 || byte == 10 {
            skipLineFeed = byte == 13
            return try endLine()
        }
        guard line.count < Self.eventLimit else { throw ChatGPTFailure(kind: .invalidResponse, protocolIssue: .eventTooLarge) }
        line.append(byte)
        return nil
    }

    private mutating func endLine() throws -> Data? {
        defer { line.removeAll(keepingCapacity: true) }
        if firstLine {
            firstLine = false
            if line.starts(with: [239, 187, 191]) { line.removeFirst(3) }
        }
        if line.isEmpty {
            guard !data.isEmpty else { return nil }
            data.removeLast()
            defer { data = Data() }
            return data
        }

        let prefix = Array("data".utf8)
        guard line == prefix || line.starts(with: prefix + [58]) else { return nil }
        var start = min(line.count, 5)
        if start < line.count, line[start] == 32 { start += 1 }
        guard data.count + line.count - start < Self.eventLimit else { throw ChatGPTFailure(kind: .invalidResponse, protocolIssue: .eventTooLarge) }
        data.append(contentsOf: line[start...])
        data.append(10)
        return nil
    }
}

struct ChatGPTResponseStream {
    enum Event: Equatable {
        case text(String)
        case completed
        case ignored
    }

    private(set) var completed = false

    mutating func consume(_ data: Data, requestID: String? = nil, token: String = "") throws -> Event {
        if data.isEmpty || data == Data("[DONE]".utf8) { return .ignored }
        let decoder = JSONDecoder()
        guard let event = try? decoder.decode(EventType.self, from: data) else {
            if var failure = ChatGPTFailure.serviceError(data, requestID: requestID, secrets: [token]) {
                failure.streamEnd = .serverError
                throw failure
            }
            throw ChatGPTFailure(kind: .invalidResponse, requestID: requestID, protocolIssue: .invalidEvent)
        }
        // Decode fields only for the selected event type. Other event payloads have different schemas.
        switch event.type {
        case "response.output_text.delta", "response.refusal.delta":
            guard let text = try? decoder.decode(TextDelta.self, from: data) else {
                throw ChatGPTFailure(kind: .invalidResponse, requestID: requestID, protocolIssue: .missingDelta)
            }
            return .text(text.delta)
        case "response.completed":
            guard let envelope = try? decoder.decode(ResponseEnvelope.self, from: data),
                  let response = envelope.response,
                  response.status == nil || response.status == "completed" else {
                throw ChatGPTFailure(kind: .invalidResponse, requestID: requestID, protocolIssue: .invalidCompletion)
            }
            completed = true
            return .completed
        case "response.failed", "error":
            let envelope = try? decoder.decode(ResponseEnvelope.self, from: data)
            let error = envelope?.response?.error ?? envelope?.error
            var failure = ChatGPTFailure.remote(code: error?.code ?? envelope?.code,
                                                parameter: error?.param ?? envelope?.param,
                                                detail: error?.message ?? envelope?.message,
                                                requestID: requestID, secrets: [token])
            failure.streamEnd = event.type == "error" ? .serverError : .failed
            throw failure
        case "response.incomplete":
            let envelope = try? decoder.decode(ResponseEnvelope.self, from: data)
            let explanation: String? = switch envelope?.response?.incompleteDetails?.reason {
            case "max_output_tokens": "The model reached its output limit."
            case "content_filter": "The response stopped because of a content filter."
            default: nil
            }
            throw ChatGPTFailure(kind: .incomplete, requestID: requestID, detail: explanation, streamEnd: .incomplete)
        case "response.cancelled":
            throw ChatGPTFailure(kind: .interrupted, requestID: requestID,
                                 detail: "ChatGPT cancelled the response.", streamEnd: .serverCancelled)
        default:
            return .ignored
        }
    }

    func finish(requestID: String? = nil) throws {
        guard completed else {
            throw ChatGPTFailure(kind: .interrupted, requestID: requestID, streamEnd: .interrupted)
        }
    }

    private struct EventType: Decodable {
        let type: String
    }

    private struct TextDelta: Decodable {
        let delta: String
    }

    private struct ResponseEnvelope: Decodable {
        let response: Response?
        let error: ChatGPTFailure.StructuredError?
        let code: String?
        let param: String?
        let message: String?

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Keys.self)
            response = try? fields.decode(Response.self, forKey: .response)
            error = try? fields.decode(ChatGPTFailure.StructuredError.self, forKey: .error)
            code = try? fields.decode(String.self, forKey: .code)
            param = try? fields.decode(String.self, forKey: .param)
            message = try? fields.decode(String.self, forKey: .message)
        }

        private enum Keys: String, CodingKey { case response, error, code, param, message }
    }

    private struct Response: Decodable {
        let status: String?
        let error: ChatGPTFailure.StructuredError?
        let incompleteDetails: Incomplete?

        private enum CodingKeys: String, CodingKey {
            case status, error
            case incompleteDetails = "incomplete_details"
        }
    }

    private struct Incomplete: Decodable {
        let reason: String?
    }
}
