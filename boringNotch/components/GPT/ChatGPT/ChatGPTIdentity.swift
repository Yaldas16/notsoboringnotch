import CryptoKit
import Foundation
import Security

enum ChatGPTBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: Substring) -> Data? {
        guard value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), value.count % 4 != 1 else { return nil }
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }
}

struct ChatGPTAuthorizationAttempt {
    let state: String
    let nonce: String
    let verifier: String

    var challenge: String {
        ChatGPTBase64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    init() throws {
        state = try Self.randomValue()
        nonce = try Self.randomValue()
        verifier = try Self.randomValue()
    }

    func url(clientID: String, hostID: String, redirectURI: String, requestConsent: Bool) throws -> URL {
        var components = URLComponents(url: ChatGPTEndpoints.authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "ext_agent_host_id", value: hostID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: ChatGPTEndpoints.scopes),
            .init(name: "resource", value: ChatGPTEndpoints.resource),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]
        if clientID == ChatGPTEndpoints.dynamicClient {
            components.queryItems?.append(.init(name: "agent_name_hint", value: "NotSoBoringNotch"))
        } else if requestConsent {
            components.queryItems?.append(.init(name: "prompt", value: "consent"))
        }
        guard let url = components.url else { throw ChatGPTFailure(kind: .invalidResponse) }
        return url
    }

    private static func randomValue() throws -> String {
        var bytes = Data(count: 32)
        let result = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard result == errSecSuccess else { throw ChatGPTFailure(kind: .invalidIdentity) }
        return ChatGPTBase64URL.encode(bytes)
    }
}

struct ChatGPTIdentity: Codable, Equatable, Sendable {
    let subject: String
    let email: String?
    let name: String?
}

enum ChatGPTIDToken {
    struct KeySet: Decodable, Sendable {
        let keys: [Key]
    }

    struct Key: Decodable, Sendable {
        let kty: String
        let kid: String
        let use: String?
        let alg: String?
        let n: String?
        let e: String?

        fileprivate var rsaPublicKey: SecKey? {
            guard kty == "RSA", use == nil || use == "sig", alg == nil || alg == "RS256",
                  let n, let e,
                  let modulus = ChatGPTBase64URL.decode(n[...]), (256...1024).contains(modulus.count),
                  let exponent = ChatGPTBase64URL.decode(e[...]), (1...8).contains(exponent.count)
            else { return nil }

            let der = ChatGPTIDToken.der(0x30, ChatGPTIDToken.integer(modulus) + ChatGPTIDToken.integer(exponent))
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPublic,
            ]
            return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
        }
    }

    static func verify(_ token: String, keys: KeySet, clientID: String, nonce: String, now: Date = .now) throws -> ChatGPTIdentity {
        let failure = ChatGPTFailure(kind: .invalidIdentity)
        guard token.utf8.count <= 32_768 else { throw failure }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        let decoder = JSONDecoder()
        guard parts.count == 3, let headerData = ChatGPTBase64URL.decode(parts[0]),
              let claimsData = ChatGPTBase64URL.decode(parts[1]), let signature = ChatGPTBase64URL.decode(parts[2]),
              let header = try? decoder.decode(Header.self, from: headerData),
              header.alg == "RS256", header.crit == nil,
              let jwk = keys.keys.first(where: { $0.kid == header.kid }),
              let key = jwk.rsaPublicKey
        else { throw failure }

        let input = Data((parts[0] + "." + parts[1]).utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, signature as CFData, nil),
              let claims = try? decoder.decode(Claims.self, from: claimsData),
              claims.iss == ChatGPTEndpoints.issuer,
              claims.aud.values.contains(clientID),
              (claims.aud.values.count == 1 || claims.azp == clientID),
              (claims.azp == nil || claims.azp == clientID),
              claims.exp > now.timeIntervalSince1970,
              (claims.nbf ?? 0) <= now.timeIntervalSince1970,
              claims.nonce == nonce,
              !claims.sub.isEmpty
        else { throw failure }
        return ChatGPTIdentity(subject: claims.sub, email: claims.email, name: claims.name)
    }

    private struct Header: Decodable {
        let alg: String
        let kid: String
        let crit: [String]?
    }

    private struct Claims: Decodable {
        let iss: String
        let sub: String
        let aud: Audience
        let azp: String?
        let exp: Double
        let nbf: Double?
        let nonce: String
        let email: String?
        let name: String?
    }

    private struct Audience: Decodable {
        let values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let one = try? container.decode(String.self) {
                values = [one]
            } else {
                values = try container.decode([String].self)
            }
        }
    }

    // Security imports RSA public keys as a PKCS#1 DER sequence of unsigned n and e.
    private static func integer(_ data: Data) -> Data {
        let magnitude = Data(data.drop(while: { $0 == 0 }))
        guard let first = magnitude.first else { return der(0x02, Data([0])) }
        return der(0x02, (first & 0x80 == 0) ? magnitude : Data([0]) + magnitude)
    }

    private static func der(_ tag: UInt8, _ content: Data) -> Data {
        var remaining = content.count
        if remaining < 128 { return Data([tag, UInt8(remaining)]) + content }
        var length: [UInt8] = []
        while remaining > 0 {
            length.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
            remaining >>= 8
        }
        return Data([tag, 0x80 | UInt8(length.count)] + length) + content
    }
}
