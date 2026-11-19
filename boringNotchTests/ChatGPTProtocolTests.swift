import Foundation
import Security
import XCTest
@testable import boringNotch

final class ChatGPTProtocolTests: XCTestCase {
    func testAuthorizationUsesFreshValuesAndDocumentedParameters() throws {
        let first = try ChatGPTAuthorizationAttempt()
        let second = try ChatGPTAuthorizationAttempt()
        XCTAssertTrue(first.state != second.state && first.nonce != second.nonce && first.verifier != second.verifier)
        XCTAssertTrue(first.challenge != first.verifier)
        let host = "urn:uuid:" + UUID().uuidString
        let redirect = "http://127.0.0.1:54321/auth/callback"
        func params(_ client: String, consent: Bool = false) throws -> [String: String?] {
            let url = try first.url(clientID: client, hostID: host, redirectURI: redirect, requestConsent: consent)
            XCTAssertEqual(url.host, "auth.openai.com")
            XCTAssertEqual(url.path, "/api/accounts/authorize")
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        }
        let initial = try params(ChatGPTEndpoints.dynamicClient)
        XCTAssertEqual(initial["agent_name_hint"], "NotSoBoringNotch")
        XCTAssertEqual(initial["redirect_uri"], redirect)
        XCTAssertEqual(initial["ext_agent_host_id"], host)
        XCTAssertEqual(initial["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(initial["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        XCTAssertEqual(initial["code_challenge_method"], "S256")
        let returning = try params("oaiapp_fixture")
        XCTAssertNil(returning["agent_name_hint"])
        XCTAssertNil(returning["id_token_hint"])
        XCTAssertNil(returning["prompt"])
        XCTAssertEqual(try params("oaiapp_fixture", consent: true)["prompt"], "consent")
    }

    func testCallbackChecksStateAndReturningClientBeforeExchange() throws {
        let port: UInt16 = 14471
        func parse(_ query: String, host: String = "127.0.0.1:14471") throws -> ChatGPTCallback? {
            try ChatGPTCallback.parse(
                Data("GET /auth/callback?\(query) HTTP/1.1\r\nHost: \(host)".utf8), port: port, state: "pending"
            )
        }
        XCTAssertNil(try parse("state=wrong&code=fixture"))
        XCTAssertNil(try parse("state=pending&state=pending&code=fixture"))
        XCTAssertNil(try parse("state=pending&code=fixture", host: "other.local"))
        XCTAssertThrowsError(try parse("state=pending&error=access_denied")) {
            XCTAssertEqual(($0 as? ChatGPTFailure)?.kind, .consent)
        }

        let noClient = try XCTUnwrap(parse("state=pending&code=fixture"))
        XCTAssertEqual(try noClient.issuedClientID(for: "oaiapp_original"), "oaiapp_original")
        XCTAssertThrowsError(try noClient.issuedClientID(for: ChatGPTEndpoints.dynamicClient))
        let newClient = try XCTUnwrap(parse("state=pending&code=fixture&client_id=oaiapp_issued"))
        XCTAssertEqual(try newClient.issuedClientID(for: ChatGPTEndpoints.dynamicClient), "oaiapp_issued")
        XCTAssertThrowsError(try newClient.issuedClientID(for: "oaiapp_other"))
    }

    @MainActor
    func testBrowserCallbackBindsToLoopbackAndRejectsAnotherAttempt() async throws {
        let state = UUID().uuidString
        let loopback = try ChatGPTLoopback(state: state)
        let client = URLSession(configuration: .ephemeral)
        defer {
            loopback.stop()
            client.invalidateAndCancel()
        }
        loopback.start()
        var events = loopback.events.makeAsyncIterator()
        guard case .ready(let port)? = try await events.next() else {
            XCTFail("Loopback listener did not start")
            return
        }

        let base = "http://127.0.0.1:\(port)/auth/callback"
        let (_, invalid) = try await client.data(from: XCTUnwrap(URL(string: base + "?state=another&code=fixture")))
        XCTAssertEqual((invalid as? HTTPURLResponse)?.statusCode, 400)
        let callback = URL(string: base + "?state=\(state)&code=fixture&client_id=oaiapp_fixture")
        let (page, result) = try await client.data(from: XCTUnwrap(callback))
        XCTAssertEqual((result as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(String(decoding: page, as: UTF8.self).contains(state))
        guard case .callback(let valid)? = try await events.next() else {
            XCTFail("Validated browser callback was not delivered")
            return
        }
        XCTAssertEqual(try valid.issuedClientID(for: ChatGPTEndpoints.dynamicClient), "oaiapp_fixture")
    }

    func testIDTokenChecksSignatureIssuerAudienceExpiryAndNonce() throws {
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
        ] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let encoded = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var index = 0
        let rsaParameters = [UInt8](try readDER([UInt8](encoded), offset: &index, tag: 0x30))
        index = 0
        let n = try readDER(rsaParameters, offset: &index, tag: 0x02)
        let e = try readDER(rsaParameters, offset: &index, tag: 0x02)
        let keys = ChatGPTIDToken.KeySet(keys: [
            .init(kty: "RSA", kid: "fixture", use: "sig", alg: "RS256",
                  n: ChatGPTBase64URL.encode(n), e: ChatGPTBase64URL.encode(e))
        ])

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let audience = "oaiapp_fixture"
        let nonce = UUID().uuidString
        func sign(issuer: String = ChatGPTEndpoints.issuer, aud: String? = nil,
                  expiration: TimeInterval? = nil, nonceClaim: String? = nil) throws -> String {
            let header = Data(#"{"alg":"RS256","kid":"fixture"}"#.utf8)
            let claims = try JSONSerialization.data(withJSONObject: [
                "iss": issuer, "aud": aud ?? audience, "sub": "subject_fixture", "email": "test@example.com",
                "exp": expiration ?? now.timeIntervalSince1970 + 60, "nonce": nonceClaim ?? nonce,
            ])
            let input = ChatGPTBase64URL.encode(header) + "." + ChatGPTBase64URL.encode(claims)
            let signature = try XCTUnwrap(SecKeyCreateSignature(
                privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil
            )) as Data
            return input + "." + ChatGPTBase64URL.encode(signature)
        }
        func verify(_ token: String) throws -> ChatGPTIdentity {
            try ChatGPTIDToken.verify(token, keys: keys, clientID: audience, nonce: nonce, now: now)
        }
        let valid = try sign()
        XCTAssertEqual(try verify(valid).email, "test@example.com")
        XCTAssertThrowsError(try verify(sign(issuer: "https://example.com")))
        XCTAssertThrowsError(try verify(sign(aud: "another-client")))
        XCTAssertThrowsError(try verify(sign(expiration: now.timeIntervalSince1970)))
        XCTAssertThrowsError(try verify(sign(nonceClaim: "wrong-attempt")))
        let payload = valid.split(separator: ".")
        let corrupted = payload[0] + "." + payload[1] + "." + ChatGPTBase64URL.encode(Data(repeating: 0, count: 256))
        XCTAssertThrowsError(try verify(corrupted))
    }

    func testSSEAcceptsSplitUnicodeAndRequiresVerifiedCompletion() throws {
        let wire = "\u{FEFF}: keepalive\r\n\r\nevent: response.output_text.delta\r\n" +
            "data: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"İstanbul 🐈\"}\r\n\r\n" +
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
        var parser = ChatGPTSSEParser()
        var response = ChatGPTResponseStream()
        var events: [ChatGPTResponseStream.Event] = []
        for byte in wire.utf8 {
            if let message = try parser.append(byte) {
                events.append(try response.consume(message))
            }
        }
        XCTAssertEqual(events, [.text("İstanbul 🐈"), .completed])
        XCTAssertNoThrow(try response.finish())

        var interrupted = ChatGPTResponseStream()
        XCTAssertEqual(try interrupted.consume(Data("[DONE]".utf8)), .ignored)
        XCTAssertThrowsError(try interrupted.finish()) {
            XCTAssertEqual(($0 as? ChatGPTFailure)?.kind, .interrupted)
        }
    }

    func testSSETerminalErrorsAndAdmissionDetailsAreRecoverableAndRedacted() throws {
        var response = ChatGPTResponseStream()
        let failed = Data(#"{"type":"response.failed","response":{"status":"failed","error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#.utf8)
        XCTAssertThrowsError(try response.consume(failed)) {
            XCTAssertEqual(($0 as? ChatGPTFailure)?.kind, .usageLimit)
            XCTAssertTrue(($0 as? ChatGPTFailure)?.pausesSending == true)
        }
        let incomplete = Data(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"content_filter"}}}"#.utf8)
        XCTAssertThrowsError(try response.consume(incomplete)) {
            XCTAssertEqual(($0 as? ChatGPTFailure)?.kind, .incomplete)
        }
        XCTAssertFalse(response.completed)

        let privateValue = UUID().uuidString
        let body = try JSONSerialization.data(withJSONObject: ["detail": "Region restricted. Credential: \(privateValue)"])
        let http = try XCTUnwrap(HTTPURLResponse(
            url: ChatGPTEndpoints.responses, statusCode: 403, httpVersion: nil, headerFields: ["x-request-id": "req_fixture"]
        ))
        let admission = ChatGPTFailure.response(http, data: body, secrets: [privateValue])
        XCTAssertEqual(admission.kind, .forbidden)
        XCTAssertEqual(admission.status, 403)
        XCTAssertEqual(admission.requestID, "req_fixture")
        XCTAssertTrue(admission.detail?.contains("Region restricted") == true)
        XCTAssertFalse(admission.localizedDescription.contains(privateValue))
    }

    func testInferenceBodyUsesOnlyDocumentedFieldsAndMemoryContext() throws {
        let request = try ChatGPTLiveAPI.responseRequest(model: "catalog-model-fixture", messages: [
            GPTMessage(role: .user, text: "Hello"), GPTMessage(role: .assistant, text: "Hi"),
            GPTMessage(role: .user, text: "Continue"),
        ], token: UUID().uuidString)
        XCTAssertEqual(request.url, ChatGPTEndpoints.responses)
        XCTAssertEqual(request.httpMethod, "POST")
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "input", "store", "stream"])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["model"] as? String, "catalog-model-fixture")
        let messages = try XCTUnwrap(body["input"] as? [[String: String]])
        XCTAssertEqual(messages.compactMap { $0["role"] }, ["user", "assistant", "user"])
        XCTAssertEqual(messages.last?["content"], "Continue")
    }

    private func readDER(_ bytes: [UInt8], offset: inout Int, tag: UInt8) throws -> Data {
        guard offset + 1 < bytes.count, bytes[offset] == tag else { throw ChatGPTFailure(kind: .invalidIdentity) }
        let first = Int(bytes[offset + 1])
        offset += 2
        var length = first
        if first >= 128 {
            let size = first & 127
            guard (1...4).contains(size), offset + size <= bytes.count else { throw ChatGPTFailure(kind: .invalidIdentity) }
            length = 0
            for byte in bytes[offset..<(offset + size)] { length = (length << 8) | Int(byte) }
            offset += size
        }
        guard offset + length <= bytes.count else { throw ChatGPTFailure(kind: .invalidIdentity) }
        defer { offset += length }
        return Data(bytes[offset..<(offset + length)])
    }
}
