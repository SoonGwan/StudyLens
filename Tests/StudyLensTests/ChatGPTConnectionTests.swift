import Foundation
import Security
import XCTest
@testable import StudyLens

final class ChatGPTConnectionTests: XCTestCase {
    func testPKCEReferenceVector() {
        XCTAssertEqual(OAuthUtilities.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testFormEncodingDoesNotChangeReservedCharacters() {
        let form = String(decoding: OAuthUtilities.form(["code": "a+b&c=d /?", "resource": "https://api.openai.com/v1"]), as: UTF8.self)
        XCTAssertTrue(form.contains("code=a%2Bb%26c%3Dd%20%2F%3F"))
    }

    func testCallbackChecksStatePathAndDuplicateParameters() throws {
        let redirect = "http://127.0.0.1:54321/auth/callback"
        let valid = URL(string: redirect + "?state=expected&code=abc&client_id=oaiapp_test")!
        let callback = try OAuthCallback.parse(valid, expectedState: "expected", redirectURI: redirect)
        XCTAssertEqual(callback.code, "abc")
        XCTAssertEqual(callback.redirectURI, redirect)
        for url in [
            redirect + "?state=wrong&code=abc",
            redirect + "?state=expected&state=wrong&code=abc",
            "http://localhost:54321/auth/callback?state=expected&code=abc",
            "http://127.0.0.1:54321/callback?state=expected&code=abc"
        ] {
            XCTAssertThrowsError(try OAuthCallback.parse(URL(string: url)!, expectedState: "expected", redirectURI: redirect))
        }
        XCTAssertThrowsError(try OAuthCallback.parse(URL(string: redirect + "?state=expected&error=access_denied")!, expectedState: "expected", redirectURI: redirect))
    }

    func testClientRegistrationCannotBeReplacedDuringReauthorization() throws {
        let callback = OAuthCallback(code: "abc", clientID: "oaiapp_other", redirectURI: "http://127.0.0.1:1/auth/callback")
        XCTAssertThrowsError(try OAuthUtilities.issuedClientID(callback: callback, previous: "oaiapp_original"))
        XCTAssertEqual(try OAuthUtilities.issuedClientID(callback: callback, previous: nil), "oaiapp_other")
        let missing = OAuthCallback(code: "abc", clientID: nil, redirectURI: callback.redirectURI)
        XCTAssertThrowsError(try OAuthUtilities.issuedClientID(callback: missing, previous: nil))
        XCTAssertEqual(try OAuthUtilities.issuedClientID(callback: missing, previous: "oaiapp_original"), "oaiapp_original")
    }

    @MainActor
    func testAuthorizationSeparatesNewRegistrationAndReturningConnection() throws {
        let newURL = ChatGPTAuthService.authorizationURL(profile: nil, hostID: "urn:uuid:test", redirectURI: "http://127.0.0.1:1/auth/callback", state: "s", nonce: "n", verifier: "v", requestConsent: false)
        let newFields = Dictionary(uniqueKeysWithValues: URLComponents(url: newURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(newFields["client_id"], "dynamic_agent_client")
        XCTAssertEqual(newFields["agent_name_hint"], "StudyLens")
        XCTAssertTrue(newFields["scope"]!.contains("chatgpt.tokens.use.direct"))
        XCTAssertNil(newFields["prompt"])
        let profile = ChatGPTProfile(clientID: "oaiapp_test", subject: "sub", email: "test@example.com", credentials: nil)
        let returning = ChatGPTAuthService.authorizationURL(profile: profile, hostID: "urn:uuid:test", redirectURI: "http://127.0.0.1:2/auth/callback", state: "s2", nonce: "n2", verifier: "v2", requestConsent: true)
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: returning, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(fields["client_id"], "oaiapp_test")
        XCTAssertNil(fields["agent_name_hint"])
        XCTAssertEqual(fields["prompt"], "consent")
        XCTAssertEqual(fields["ext_agent_host_id"], newFields["ext_agent_host_id"])
    }

    func testIdentityRequiresValidSignatureAndClaims() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let publicData = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        let (n, e) = try rsaComponents(publicData)
        let keys = JWKSet(keys: [.init(kty: "RSA", kid: "test-key", n: n.base64URL, e: e.base64URL, use: "sig", alg: "RS256")])
        let now = Date(timeIntervalSince1970: 1_000)
        let claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": "oaiapp_test", "nonce": "nonce", "exp": 2_000, "sub": "subject", "email": "test@example.com"]
        func sign(_ claims: [String: Any]) throws -> String {
            let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test-key"]).base64URL
            let payload = try JSONSerialization.data(withJSONObject: claims).base64URL
            let message = "\(header).\(payload)"
            let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil)) as Data
            return "\(message).\(signature.base64URL)"
        }
        let token = try sign(claims)
        XCTAssertEqual(try OIDCIdentity.verify(token, keys: keys, clientID: "oaiapp_test", nonce: "nonce", now: now).subject, "subject")
        for override in [["iss": "https://other.example"], ["aud": "oaiapp_other"], ["nonce": "wrong"], ["exp": 900]] as [[String: Any]] {
            var changed = claims
            changed.merge(override) { _, new in new }
            XCTAssertThrowsError(try OIDCIdentity.verify(sign(changed), keys: keys, clientID: "oaiapp_test", nonce: "nonce", now: now))
        }
        let pieces = token.split(separator: ".")
        let forged = "\(pieces[0]).\(pieces[1]).\(Data(repeating: 0, count: 256).base64URL)"
        XCTAssertThrowsError(try OIDCIdentity.verify(forged, keys: keys, clientID: "oaiapp_test", nonce: "nonce", now: now))
    }

    func testPlanRequestOmitsUnsupportedOutputLimit() throws {
        let request = ResponseRequest(model: "server-model", instructions: "test", input: [.init(role: "user", content: [.text("test")])], maxOutputTokens: nil, store: false, stream: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(json["max_output_tokens"])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertNotNil(json["input"] as? [Any])
    }

    func testStreamingRequiresCompletionAndPropagatesLateUsageError() throws {
        var stream = ResponseStreamAccumulator()
        XCTAssertNil(try stream.consume("{\"type\":\"response.output_text.delta\",\"delta\":\"설명\"}"))
        XCTAssertEqual(try stream.consume("{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}"), "설명")
        var failed = ResponseStreamAccumulator()
        _ = try failed.consume("{\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}")
        XCTAssertThrowsError(try failed.consume("{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"limit\"}}}")) { error in
            XCTAssertTrue(error.localizedDescription.contains("429"))
            XCTAssertTrue(error.localizedDescription.contains("사용 한도"))
        }
        XCTAssertThrowsError(try failed.consume("{\"type\":\"response.incomplete\"}"))
    }

    @MainActor
    func testLocalCallbackIgnoresBadStateThenAcceptsCorrectCallback() async throws {
        let server = OAuthLoopbackServer(expectedState: "expected")
        var callbackTask: Task<Void, Error>?
        let callback = try await server.authorize { uri in
            callbackTask = Task {
                let session = URLSession(configuration: .ephemeral)
                let (_, invalidResponse) = try await session.data(from: URL(string: uri + "?state=wrong&code=abc")!)
                XCTAssertEqual((invalidResponse as? HTTPURLResponse)?.statusCode, 400)
                let (_, validResponse) = try await session.data(from: URL(string: uri + "?state=expected&code=abc&client_id=oaiapp_test")!)
                XCTAssertEqual((validResponse as? HTTPURLResponse)?.statusCode, 200)
            }
        }
        try await callbackTask?.value
        XCTAssertEqual(callback.code, "abc")
        XCTAssertEqual(callback.clientID, "oaiapp_test")
        XCTAssertTrue(callback.redirectURI.hasPrefix("http://127.0.0.1:"))
    }

    @MainActor
    func testLocalCallbackCanBeCancelled() async {
        let server = OAuthLoopbackServer(expectedState: "expected")
        do {
            _ = try await server.authorize { _ in server.cancel() }
            XCTFail("Cancellation must throw")
        } catch { XCTAssertTrue(error.localizedDescription.contains("취소")) }
    }

    private func rsaComponents(_ der: Data) throws -> (Data, Data) {
        let bytes = [UInt8](der)
        var cursor = 0
        func read(_ tag: UInt8) throws -> Data {
            guard bytes[cursor] == tag else { throw ChatGPTAuthError.invalidIdentity }
            cursor += 1
            var length = Int(bytes[cursor]); cursor += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                length = 0
                for _ in 0..<count { length = (length << 8) | Int(bytes[cursor]); cursor += 1 }
            }
            let result = Data(bytes[cursor..<(cursor + length)])
            if tag != 0x30 { cursor += length }
            return result
        }
        _ = try read(0x30)
        let modulus = try read(0x02)
        let exponent = try read(0x02)
        return (Data(modulus.drop(while: { $0 == 0 })), exponent)
    }
}
