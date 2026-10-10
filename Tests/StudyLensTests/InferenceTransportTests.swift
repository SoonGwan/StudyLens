import Foundation
import XCTest
@testable import StudyLens

final class InferenceTransportTests: XCTestCase {
    override func tearDown() {
        MockInferenceProtocol.handler = nil
        super.tearDown()
    }

    func testImagePlanRequestStreamsThroughCompletedEvent() async throws {
        MockInferenceProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-oauth-token")
            let payload = try Self.body(of: request)
            XCTAssertNil(payload["max_output_tokens"])
            XCTAssertEqual(payload["stream"] as? Bool, true)
            XCTAssertEqual(payload["store"] as? Bool, false)
            let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
            let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
            XCTAssertEqual(content[1]["image_url"] as? String, "data:image/png;base64,AQID")
            let events = """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"단계별 "}

            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"설명"}

            event: response.completed
            data: {"type":"response.completed","response":{"status":"completed"}}


            """
            return (200, "text/event-stream", Data(events.utf8))
        }
        let service = makeService()
        let result = try await service.explain(imageData: Data([1, 2, 3]), credential: .init(token: "test-oauth-token", mode: .chatGPT), model: "server-model")
        XCTAssertEqual(result, "단계별 설명")
    }

    func testInterruptedStreamDoesNotReturnPartialAnswer() async throws {
        MockInferenceProtocol.handler = { _ in
            (200, "text/event-stream", Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".utf8))
        }
        do {
            _ = try await makeService().explain(selectedText: "test", credential: .init(token: "test-token", mode: .chatGPT), model: "server-model")
            XCTFail("A partial stream must not succeed")
        } catch OpenAIServiceError.interruptedStream { }
    }

    func testSSEFramesPreserveCRLFMultilineDataAndUTF8() throws {
        var framer = SSEEventFramer()
        var events: [String] = []
        let body = ": keepalive\r\ndata: 첫 줄\r\ndata: 둘째 줄\r\n\r\ndata: final\n\n"
        for byte in body.utf8 {
            if let event = try framer.append(byte) { events.append(event) }
        }
        XCTAssertEqual(events, ["첫 줄\n둘째 줄", "final"])
        XCTAssertNil(try framer.finish())
    }

    func testAPIKeyModeRetainsSeparateRequestAndLimit() async throws {
        MockInferenceProtocol.handler = { request in
            let payload = try Self.body(of: request)
            XCTAssertEqual(payload["max_output_tokens"] as? Int, 2200)
            XCTAssertEqual(payload["stream"] as? Bool, false)
            return (200, "application/json", Data("{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"API 설명\"}]}]}".utf8))
        }
        let result = try await makeService().explain(selectedText: "test", credential: .init(token: "test-key", mode: .apiKey), model: "test-model")
        XCTAssertEqual(result, "API 설명")
    }

    func testOpenAIProviderForwardsCredentialAndModel() async throws {
        MockInferenceProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let payload = try Self.body(of: request)
            XCTAssertEqual(payload["model"] as? String, "test-model")
            XCTAssertEqual(payload["instructions"] as? String, StudyPrompt.codeInstructions(language: "Go"))
            return (200, "application/json", Data("{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"코드\"}]}]}".utf8))
        }
        let provider: any InferenceProvider = OpenAIProvider(service: makeService(), credential: .init(token: "test-key", mode: .apiKey), model: "test-model")
        let result = try await provider.generateCode(selectedText: "문제", language: "Go")
        XCTAssertEqual(result, "코드")
    }

    func testSelectedTextKeepsTrailingUserRequestVerbatim() async throws {
        let selection = "문제 설명\nex1-1.png\n제한사항\n이거 Java 코드만 만들어줘"
        MockInferenceProtocol.handler = { request in
            let payload = try Self.body(of: request)
            let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
            XCTAssertEqual(input.count, 1)
            XCTAssertEqual(input[0]["role"] as? String, "user")
            let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
            XCTAssertEqual(content.count, 1)
            XCTAssertEqual(content[0]["text"] as? String, selection)
            XCTAssertEqual(payload["instructions"] as? String, StudyPrompt.instructions)
            return (200, "application/json", Data("{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"class Solution {}\"}]}]}".utf8))
        }
        let result = try await makeService().explain(selectedText: selection, credential: .init(token: "test-key", mode: .apiKey), model: "test-model")
        XCTAssertEqual(result, "class Solution {}")
    }

    func testAdmissionFailureIsReportedWithoutAlternativeBillingRequest() async throws {
        var requests = 0
        MockInferenceProtocol.handler = { _ in
            requests += 1
            return (403, "application/json", Data("{\"detail\":\"Plan usage unavailable\"}".utf8))
        }
        do {
            _ = try await makeService().explain(selectedText: "test", credential: .init(token: "test-token", mode: .chatGPT), model: "server-model")
            XCTFail("Admission rejection must throw")
        } catch OpenAIServiceError.api(let status, let message) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(message, "Plan usage unavailable")
        }
        XCTAssertEqual(requests, 1)
    }

    func testCodeGenerationUsesDedicatedPromptAndPreservesSelection() async throws {
        let selection = "문제\n이거 Python 코드로 만들어줘"
        MockInferenceProtocol.handler = { request in
            let payload = try Self.body(of: request)
            XCTAssertEqual(payload["instructions"] as? String, StudyPrompt.codeInstructions(language: "Java"))
            XCTAssertEqual(payload["max_output_tokens"] as? Int, 12000)
            let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
            let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
            XCTAssertEqual(content[0]["text"] as? String, selection)
            let data = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "```python\nprint(1)\n```"]]]]])
            return (200, "application/json", data)
        }
        let result = try await makeService().generateCode(selectedText: selection, language: "Java", credential: .init(token: "test-key", mode: .apiKey), model: "test-model")
        XCTAssertEqual(result, "```python\nprint(1)\n```")
    }

    func testIncompleteAPIResponseCannotReturnCode() async throws {
        MockInferenceProtocol.handler = { _ in
            let data = try JSONSerialization.data(withJSONObject: ["status": "incomplete", "output": [["type": "message", "content": [["type": "output_text", "text": "```java\nclass Solution {}\n```"]]]]])
            return (200, "application/json", data)
        }
        do {
            _ = try await makeService().generateCode(selectedText: "문제", language: "Java", credential: .init(token: "test-key", mode: .apiKey), model: "test-model")
            XCTFail("Incomplete response must fail")
        } catch OpenAIServiceError.interruptedStream { }
    }

    private func makeService() -> OpenAIService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockInferenceProtocol.self]
        return OpenAIService(session: URLSession(configuration: configuration))
    }

    private static func body(of request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class MockInferenceProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, type, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
