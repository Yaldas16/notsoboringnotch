import Foundation
import OSLog

enum ChatGPTRequestStage: String, Sendable {
    case models, modelDecoding, submission, stream, refresh

    var endpoint: String {
        switch self {
        case .models, .modelDecoding: "/v1/models"
        case .submission, .stream: "/v1/responses"
        case .refresh: "/api/accounts/oauth/token"
        }
    }

    var action: String {
        switch self {
        case .models, .modelDecoding: "Loading models"
        case .submission: "Sending the message"
        case .stream: "Receiving the response"
        case .refresh: "Refreshing the ChatGPT session"
        }
    }
}

enum ChatGPTProtocolIssue: String, Sendable {
    case nonHTTP, invalidJSON, ordinaryCatalog, invalidCatalog, noVisibleModels, wrongContentType
    case invalidEvent, missingDelta, invalidCompletion, eventTooLarge

    var message: String {
        switch self {
        case .nonHTTP: "The connection did not return an HTTP response."
        case .invalidJSON: "The server did not return a readable JSON document."
        case .ordinaryCatalog: "The server returned the ordinary API model catalog instead of the ChatGPT plan catalog."
        case .invalidCatalog: "The response did not contain the documented ChatGPT plan model list."
        case .noVisibleModels: "The ChatGPT plan catalog did not contain any selectable models."
        case .wrongContentType: "The server did not open a server-sent event stream."
        case .invalidEvent: "The stream contained an invalid event."
        case .missingDelta: "A text event did not contain a valid text delta."
        case .invalidCompletion: "The stream ended with an inconsistent completion event."
        case .eventTooLarge: "A stream event exceeded the app’s size limit."
        }
    }
}

enum ChatGPTStreamEnd: String, Sendable {
    case completed, failed, incomplete, serverError, serverCancelled, malformed, interrupted, network, cancelled, notOpened
}

struct ChatGPTRequestTrace: Sendable {
    private static let logger = Logger(subsystem: "com.yusuf.boringnotch.personal.chatgpt", category: "requests")

    let stage: ChatGPTRequestStage
    let status: Int?
    let requestID: String?
    let contentType: String?

    init(_ stage: ChatGPTRequestStage, _ response: HTTPURLResponse? = nil, secrets: [String] = []) {
        self.stage = stage
        status = response?.statusCode
        requestID = Self.safeIdentifier(response?.requestID, secrets: secrets)
        contentType = Self.mediaType(response?.value(forHTTPHeaderField: "Content-Type"), secrets: secrets)
    }

    init(_ stage: ChatGPTRequestStage, copying other: Self) {
        self.stage = stage
        status = other.status
        requestID = other.requestID
        contentType = other.contentType
    }

    func attach(_ failure: ChatGPTFailure) -> ChatGPTFailure {
        var result = failure
        result.trace = self
        result.status = status ?? failure.status
        result.requestID = requestID
        return result
    }

    func record(_ message: StaticString, failure: ChatGPTFailure? = nil, end: ChatGPTStreamEnd? = nil) {
        let statusText = status.map(String.init) ?? "-"
        let request = requestID ?? "-"
        let type = contentType ?? "-"
        let code = Self.safeIdentifier(failure?.code) ?? "-"
        let parameter = Self.safeParameter(failure?.parameter) ?? "-"
        let body = failure?.bodyShape.map { String(describing: $0) } ?? "-"
        let diagnostic = failure?.protocolIssue?.message ?? failure?.summary ?? String(describing: message)
        let termination = end?.rawValue ?? "-"
        // Only log local diagnostic text and validated metadata. Never interpolate server text or payloads.
        Self.logger.notice("stage=\(stage.rawValue, privacy: .public) endpoint=\(stage.endpoint, privacy: .public) status=\(statusText, privacy: .public) request_id=\(request, privacy: .public) content_type=\(type, privacy: .public) code=\(code, privacy: .public) param=\(parameter, privacy: .public) body=\(body, privacy: .public) termination=\(termination, privacy: .public) message=\(diagnostic, privacy: .public)")
    }

    static func safeIdentifier(_ value: String?, secrets: [String] = []) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              !secrets.contains(where: { !$0.isEmpty && value.contains($0) })
        else { return nil }
        return value
    }

    private static func safeParameter(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 128,
              value.range(of: #"^[a-zA-Z_][a-zA-Z0-9_]*(?:(?:\[\d+\])|(?:\.[a-zA-Z_][a-zA-Z0-9_]*))*$"#,
                          options: .regularExpression) != nil else { return nil }
        return value
    }

    private static func mediaType(_ value: String?, secrets: [String]) -> String? {
        guard let value = value?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              value.utf8.count <= 96,
              value.range(of: #"^[a-z0-9.+_-]+/[a-z0-9.+_-]+$"#, options: .regularExpression) != nil,
              !secrets.contains(where: { !$0.isEmpty && value.contains($0.lowercased()) })
        else { return nil }
        return value
    }
}
