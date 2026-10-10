import AppKit
import Foundation
import XCTest
@testable import StudyLens

final class InferenceTransportTests: XCTestCase {
    override func tearDown() {
        MockInferenceProtocol.handler = nil
        super.tearDown()
    }

    func testImagePlanRequestStreamsThroughCompletedEvent() async throws {
        let imageData = try Self.png()
        MockInferenceProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-oauth-token")
            let payload = try Self.body(of: request)
            XCTAssertNil(payload["max_output_tokens"])
            XCTAssertEqual(payload["stream"] as? Bool, true)
            XCTAssertEqual(payload["store"] as? Bool, false)
            let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
            let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
            XCTAssertEqual(content[1]["image_url"] as? String, "data:image/png;base64,\(imageData.base64EncodedString())")
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
        let result = try await service.explain(imageData: imageData, credential: .init(token: "test-oauth-token", mode: .chatGPT), model: "gpt-6.1-sol")
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
            XCTAssertEqual(payload["stream"] as? Bool, true)
            return (200, "application/json", Data("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"API 설명\"}]}]}".utf8))
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
            return (200, "application/json", Data("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"코드\"}]}]}".utf8))
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
            return (200, "application/json", Data("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"class Solution {}\"}]}]}".utf8))
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

    static func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testReasoningEffortInAllInputRoutesAndBothBillingModes() async throws {
        let png = try Self.png()
        for mode in [BillingMode.apiKey, .chatGPT] {
            for effort in ["low", "medium", "high"] {
                var requests = 0
                MockInferenceProtocol.handler = { request in
                    requests += 1
                    let body = try Self.body(of: request)
                    XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], effort)
                    XCTAssertEqual(body["model"] as? String, "gpt-6.1-sol")
                    XCTAssertEqual(body["store"] as? Bool, false)
                    XCTAssertEqual(body["stream"] as? Bool, true)
                    return (200, "text/event-stream", Data(Self.completedSSE.utf8))
                }
                let credential = InferenceCredential(token: "synthetic", mode: mode)
                let provider: any InferenceProvider = OpenAIProvider(service: makeService(), credential: credential,
                                                                     model: "gpt-6.1-sol", reasoningEffort: effort)
                _ = try await provider.explain(imageData: png)
                _ = try await provider.explain(selectedText: "본문")
                _ = try await provider.generateCode(selectedText: "본문", language: "Java")
                XCTAssertEqual(requests, 3)
            }
        }
    }

    func testReasoningOmittedForUnknownUnsupportedAndDefaultValues() async throws {
        for (model, effort) in [("gpt-4.1-mini", "low"), ("unknown-model", "high"), ("gpt-6.1-sol", "modelDefault"), ("gpt-6.1-sol", "none"), ("gpt-6.1-sol", "minimal")] {
            MockInferenceProtocol.handler = { request in
                XCTAssertNil(try Self.body(of: request)["reasoning"])
                return (200, "text/event-stream", Data(Self.completedSSE.utf8))
            }
            _ = try await makeService().generateCode(selectedText: "본문", language: "Java", credential: .init(token: "synthetic", mode: .apiKey), model: model, reasoningEffort: effort)
        }
    }

    func testTextInstructionAndImageAreOneUserMessageInBothModes() async throws {
        let png = try Self.png()
        for mode in [BillingMode.apiKey, .chatGPT] {
            MockInferenceProtocol.handler = { request in
                let body = try Self.body(of: request)
                let inputs = try XCTUnwrap(body["input"] as? [[String: Any]])
                XCTAssertEqual(inputs.count, 1)
                XCTAssertEqual(inputs[0]["role"] as? String, "user")
                let content = try XCTUnwrap(inputs[0]["content"] as? [[String: Any]])
                XCTAssertEqual(content.count, 3)
                XCTAssertEqual(content[0]["text"] as? String, "본문\nex1-1.png\nPython으로 만들어줘")
                XCTAssertEqual(content[1]["text"] as? String, "추가 지시:\n그림의 화살표 방향을 사용해 줘")
                XCTAssertEqual(content[2]["image_url"] as? String, "data:image/png;base64,\(png.base64EncodedString())")
                return (200, "text/event-stream", Data(Self.completedSSE.utf8))
            }
            let credential = InferenceCredential(token: "synthetic", mode: mode)
            let provider: any InferenceProvider = OpenAIProvider(service: makeService(), credential: credential,
                                                                 model: "gpt-6.1-sol", imageData: png,
                                                                 additionalInstructions: "그림의 화살표 방향을 사용해 줘")
            _ = try await provider.explain(selectedText: "본문\nex1-1.png\nPython으로 만들어줘")
            _ = try await provider.generateCode(selectedText: "본문\nex1-1.png\nPython으로 만들어줘", language: "Java")
        }
    }

    func testInvalidAttachmentsAndInputFailBeforeNetwork() async throws {
        let png = try Self.png()
        var requests = 0
        MockInferenceProtocol.handler = { _ in requests += 1; XCTFail("Invalid input was sent"); return (500, "application/json", Data()) }
        for (image, model) in [(png, "unknown-model"), (Data([1, 2, 3]), "gpt-6.1-sol"), (Data(count: InputAttachment.maximumBytes + 1), "gpt-6.1-sol")] {
            do {
                _ = try await makeService().explain(selectedText: "본문", credential: .init(token: "synthetic", mode: .apiKey), model: model, imageData: image)
                XCTFail("Must reject invalid image")
            } catch { XCTAssertTrue(error is InputValidationError) }
        }
        do {
            _ = try await makeService().explain(selectedText: "본문", credential: .init(token: "synthetic", mode: .apiKey), model: "gpt-6.1-sol", additionalInstructions: String(repeating: "x", count: 2001))
            XCTFail("Must reject long additional instructions")
        } catch { XCTAssertEqual(error as? InputValidationError, .instructionsTooLong) }
        XCTAssertEqual(requests, 0)
    }

    func testFirstEventAndFirstOutputProgressAreDistinct() async throws {
        let events = ProgressEvents()
        MockInferenceProtocol.handler = { _ in
            (200, "text/event-stream", Data(("data: {\"type\":\"response.created\"}\n\n" + Self.completedSSE).utf8))
        }
        _ = try await makeService().explain(selectedText: "본문", credential: .init(token: "synthetic", mode: .chatGPT), model: "gpt-6.1-sol", onProgress: { events.append($0) })
        XCTAssertEqual(events.values, [.firstEvent, .firstText, .completed])
    }

    @MainActor
    func testAppCodeFlowReadsTextThenExplicitImageWithoutOpeningResult() async throws {
        let png = try Self.png()
        var order: [String] = []
        var opened = 0
        let pasteboard = NSPasteboard(name: .init("StudyLens.InputFlow.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let observer = NotificationCenter.default.addObserver(forName: .studyLensOpenResult, object: nil, queue: .main) { _ in opened += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        MockInferenceProtocol.handler = { request in
            let input = try XCTUnwrap(try Self.body(of: request)["input"] as? [[String: Any]])
            XCTAssertEqual((input[0]["content"] as? [[String: Any]])?.count, 3)
            return (200, "text/event-stream", Data(Self.completedSSE.utf8))
        }
        let model = AppModel(startServices: false, openAIService: makeService(),
            selectionReader: { prompt in XCTAssertFalse(prompt); order.append("text"); return "problem" },
            imageCapturer: { prompt in XCTAssertFalse(prompt); order.append("image"); return png },
            credentialProvider: { mode, selectedModel in
                XCTAssertEqual(mode, .apiKey); XCTAssertEqual(selectedModel, "gpt-6.1-sol")
                order.append("credential"); return .init(token: "synthetic", mode: mode)
            }, clipboardWriter: { ResponseClipboard.copy($0, to: pasteboard) })
        let previous = (model.modelName, model.billingMode, model.additionalInstructions)
        defer { model.modelName = previous.0; model.billingMode = previous.1; model.additionalInstructions = previous.2 }
        model.modelName = "gpt-6.1-sol"
        model.billingMode = .apiKey
        model.additionalInstructions = "그림 참고"
        await model.copySelectedCode(attachImage: true)
        XCTAssertEqual(order, ["text", "image", "credential"])
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(pasteboard.string(forType: .string), "class Solution {}\n")
        XCTAssertEqual(opened, 0)
        order = []
        model.additionalInstructions = ""
        MockInferenceProtocol.handler = { request in
            let input = try XCTUnwrap(try Self.body(of: request)["input"] as? [[String: Any]])
            XCTAssertEqual((input[0]["content"] as? [[String: Any]])?.count, 1)
            return (200, "text/event-stream", Data(Self.completedSSE.utf8))
        }
        await model.copySelectedCode(attachImage: false)
        XCTAssertEqual(order, ["text", "credential"])
        XCTAssertEqual(opened, 0)
    }

    @MainActor
    func testImagePickerCancellationPreservesClipboardAndDoesNotAuthenticateOrSend() async {
        var requests = 0
        MockInferenceProtocol.handler = { _ in requests += 1; XCTFail("Cancelled picker sent request"); return (500, "application/json", Data()) }
        let pasteboard = NSPasteboard(name: .init("StudyLens.CancelInput.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(ResponseClipboard.copy("previous", to: pasteboard))
        let model = AppModel(startServices: false, openAIService: makeService(), selectionReader: { _ in "problem" },
            imageCapturer: { _ in throw ScreenCaptureError.cancelled }, credentialProvider: { _, _ in
                XCTFail("Cancelled picker authenticated"); return .init(token: "synthetic", mode: .apiKey)
            }, clipboardWriter: { ResponseClipboard.copy($0, to: pasteboard) })
        let previous = model.modelName
        defer { model.modelName = previous }
        model.modelName = "gpt-6.1-sol"
        model.billingMode = .apiKey
        await model.copySelectedCode(attachImage: true)
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.requestProgress?.stage, .cancelled)
        XCTAssertEqual(pasteboard.string(forType: .string), "previous")
        XCTAssertEqual(requests, 0)
    }

    func testJSONWithoutTerminalStatusCannotReturnCode() async throws {
        MockInferenceProtocol.handler = { _ in
            let data = try JSONSerialization.data(withJSONObject: ["output": [["type": "message", "content": [["type": "output_text", "text": "```java\nclass Solution {}\n```"]]]]])
            return (200, "application/json", data)
        }
        do {
            _ = try await makeService().generateCode(selectedText: "problem", language: "Java", credential: .init(token: "synthetic", mode: .apiKey), model: "gpt-6.1-sol")
            XCTFail("Completion status is required")
        } catch OpenAIServiceError.interruptedStream { }
    }

    private static let completedSSE = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"```java\\nclass Solution {}\\n```\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"

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

private final class ProgressEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InferenceProgressEvent] = []
    func append(_ event: InferenceProgressEvent) { lock.lock(); defer { lock.unlock() }; storage.append(event) }
    var values: [InferenceProgressEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}
