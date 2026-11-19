import Foundation
import XCTest
@testable import boringNotch

final class ChatGPTResponseRegressionTests: XCTestCase {
    func testCatalogUsesPlanSlugsInServerOrderAndSkipsUnusableEntries() throws {
        let catalog = Data("""
        {"models":[
            {"slug":"second-alphabetically","display_name":"First choice","visibility":"list"},
            {"slug":"hidden","display_name":{"internal":true},"visibility":"hide"},
            null,
            {"slug":"second-alphabetically","display_name":"Duplicate","visibility":"list"},
            {"slug":"first-alphabetically","display_name":"Second choice","visibility":"list"}
        ]}
        """.utf8)

        let models = try ChatGPTLiveAPI.decodeModels(catalog)
        XCTAssertEqual(models.map(\.id), ["second-alphabetically", "first-alphabetically"])
        XCTAssertEqual(models.map(\.displayName), ["First choice", "Second choice"])
    }

    func testOrdinaryAPIResponseNeverSuppliesPlanModels() {
        let catalog = Data(#"{"object":"list","data":[{"id":"ordinary-model","object":"model"}]}"#.utf8)
        XCTAssertThrowsError(try ChatGPTLiveAPI.decodeModels(catalog)) {
            XCTAssertEqual(($0 as? ChatGPTFailure)?.protocolIssue, .ordinaryCatalog)
        }
        let malformed = Data(#"{"models":{"id":"ordinary-model"}}"#.utf8)
        XCTAssertThrowsError(try ChatGPTLiveAPI.decodeModels(malformed)) {
            XCTAssertEqual(($0 as? ChatGPTFailure)?.protocolIssue, .invalidCatalog)
        }
    }

    func testHTTP200WithNoContentTypeCanStreamFromSSEFraming() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: ChatGPTEndpoints.responses, statusCode: 200,
                                                   httpVersion: nil, headerFields: nil))
        XCTAssertNil(ChatGPTRequestTrace(.submission, response).contentType)
        let body = "\u{FEFF}\r\n: keep-alive\r\n\r\nevent: response.output_text.delta\r\n" +
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello 👋\"}\r\n\r\n" +
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\r\n\r\n"
        var bytes = body.utf8.makeIterator()
        var probe = ChatGPTSSEProbe()
        var framing: ChatGPTSSEProbe.Framing = .pending
        while framing == .pending, let byte = bytes.next() { framing = probe.append(byte) }
        XCTAssertEqual(framing, .eventStream)

        var parser = ChatGPTSSEParser()
        var stream = ChatGPTResponseStream()
        for byte in probe.prefix { XCTAssertNil(try parser.append(byte)) }
        var events: [ChatGPTResponseStream.Event] = []
        while let byte = bytes.next() {
            if let payload = try parser.append(byte) { events.append(try stream.consume(payload)) }
        }
        XCTAssertEqual(events, [.text("Hello 👋"), .completed])
        XCTAssertNoThrow(try stream.finish())
    }

    func testHeaderlessJSONAndHTMLAreNeverClassifiedAsStreams() {
        for body in [" \r\n{\"error\":{\"code\":\"server_error\"}}", "<html>error</html>"] {
            var probe = ChatGPTSSEProbe()
            var framing: ChatGPTSSEProbe.Framing = .pending
            for byte in body.utf8 where framing == .pending { framing = probe.append(byte) }
            XCTAssertEqual(framing, .other)
        }
    }

    func testUnsupportedEventPayloadDoesNotAbortAValidTextStream() throws {
        var stream = ChatGPTResponseStream()
        let auxiliary = Data(#"{"type":"response.auxiliary.delta","delta":{"fragment":true}}"#.utf8)
        XCTAssertEqual(try stream.consume(auxiliary), .ignored)
        let text = Data(#"{"type":"response.output_text.delta","delta":"Merhaba 👋"}"#.utf8)
        XCTAssertEqual(try stream.consume(text), .text("Merhaba 👋"))
        let completed = Data(#"{"type":"response.completed","response":{"id":"resp_fixture"}}"#.utf8)
        XCTAssertEqual(try stream.consume(completed), .completed)
        XCTAssertNoThrow(try stream.finish())
    }

    func testMalformedTextAndContradictoryCompletionRemainFailures() {
        var stream = ChatGPTResponseStream()
        let missing = Data(#"{"type":"response.output_text.delta","delta":{"unexpected":true}}"#.utf8)
        XCTAssertThrowsError(try stream.consume(missing)) {
            XCTAssertEqual(($0 as? ChatGPTFailure)?.protocolIssue, .missingDelta)
        }
        let contradicted = Data(#"{"type":"response.completed","response":{"status":"incomplete"}}"#.utf8)
        XCTAssertThrowsError(try stream.consume(contradicted)) {
            XCTAssertEqual(($0 as? ChatGPTFailure)?.protocolIssue, .invalidCompletion)
        }
        XCTAssertFalse(stream.completed)
    }

    func testStreamRetainsFailuresWithUnusableAncillaryFields() {
        let event = Data("""
        {"type":"response.failed","response":{"status":"failed","error":{
            "code":"subscription_sharing_usage_limit_exceeded","param":{"given":"invalid"}
        }}}
        """.utf8)
        var stream = ChatGPTResponseStream()
        XCTAssertThrowsError(try stream.consume(event, requestID: "req_stream_fixture")) {
            let failure = $0 as? ChatGPTFailure
            XCTAssertEqual(failure?.kind, .usageLimit)
            XCTAssertEqual(failure?.streamEnd, .failed)
            XCTAssertEqual(failure?.requestID, "req_stream_fixture")
        }

        let nonEvent = Data(#"{"error":{"code":"subscription_sharing_user_not_eligible","param":"model"}}"#.utf8)
        XCTAssertThrowsError(try stream.consume(nonEvent)) {
            XCTAssertEqual(($0 as? ChatGPTFailure)?.kind, .ineligible)
            XCTAssertEqual(($0 as? ChatGPTFailure)?.streamEnd, .serverError)
        }
    }

    func testHTTPStatusAndRequestIDSurviveNonJSONBodies() throws {
        let fixtures: [(Int, ChatGPTFailure.Kind)] = [
            (400, .rejected), (401, .credential), (403, .forbidden), (429, .usageLimit), (503, .server),
        ]
        for (status, kind) in fixtures {
            let response = try response(code: status, contentType: "text/html")
            let failure = ChatGPTFailure.response(response, data: Data("<html>proxy error</html>".utf8))
            let trace = ChatGPTRequestTrace(.submission, response)
            let reported = trace.attach(failure)
            XCTAssertEqual(reported.status, status)
            XCTAssertEqual(reported.kind, kind)
            XCTAssertEqual(reported.requestID, "req_fixture")
            XCTAssertEqual(reported.trace?.contentType, "text/html")
            XCTAssertEqual(reported.trace?.stage, .submission)
            XCTAssertTrue(reported.localizedDescription.contains("Request ID req_fixture"))
            XCTAssertFalse(reported.localizedDescription.contains("proxy error"))
        }
    }

    func testStructuredAdmissionErrorSurvivesUnexpectedHTTP200() throws {
        let response = try response(code: 200, contentType: "application/json")
        let body = Data(#"{"error":{"code":"subscription_sharing_unsupported_capability","param":"model"}}"#.utf8)
        let error = try XCTUnwrap(ChatGPTFailure.serviceError(body, status: response.statusCode, requestID: response.requestID))
        XCTAssertEqual(error.kind, .modelUnavailable)
        XCTAssertEqual(error.code, "subscription_sharing_unsupported_capability")
        XCTAssertEqual(error.parameter, "model")
        XCTAssertEqual(error.requestID, "req_fixture")
    }

    func testDiagnosticMetadataDropsSecretsAndContentTypeParameters() throws {
        let secret = UUID().uuidString
        let response = try XCTUnwrap(HTTPURLResponse(url: ChatGPTEndpoints.responses, statusCode: 200,
            httpVersion: nil, headerFields: ["x-request-id": secret, "Content-Type": "Text/Event-Stream; boundary=\(secret)"]))
        let trace = ChatGPTRequestTrace(.stream, response, secrets: [secret])
        XCTAssertNil(trace.requestID)
        XCTAssertEqual(trace.contentType, "text/event-stream")
        XCTAssertNil(ChatGPTRequestTrace.safeIdentifier("Bearer " + secret))
    }

    private func response(code: Int, contentType: String) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: ChatGPTEndpoints.responses, statusCode: code,
            httpVersion: nil, headerFields: ["x-request-id": "req_fixture", "Content-Type": contentType]))
    }
}
