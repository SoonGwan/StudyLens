import Foundation

enum OpenAIServiceError: LocalizedError {
    case invalidModel
    case invalidResponse
    case api(status: Int, message: String)
    case emptyOutput
    case interruptedStream

    var errorDescription: String? {
        switch self {
        case .invalidModel:
            return "모델 이름을 확인해 주세요."
        case .invalidResponse:
            return "OpenAI 응답을 읽지 못했습니다. 잠시 후 다시 시도해 주세요."
        case .api(let status, let message):
            return "OpenAI API 오류(\(status)): \(message)"
        case .emptyOutput:
            return "AI가 설명을 반환하지 않았습니다. 다른 영역을 캡처해 보세요."
        case .interruptedStream:
            return "설명이 완료되기 전에 연결이 끊겼습니다. 다시 요청해 주세요."
        }
    }
}

struct OpenAIService {
    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
    }

    func explain(imageData: Data, credential: InferenceCredential, model: String,
                 reasoningEffort: String? = nil,
                 onProgress: (@Sendable (InferenceProgressEvent) -> Void)? = nil) async throws -> String {
        guard !model.isEmpty else { throw OpenAIServiceError.invalidModel }
        try InputAttachment.validate(image: imageData, model: model)
        let payload = makeRequest(model: model, instructions: Self.instructions, content: [
            .text("화면 이미지의 내용과 사용자의 요청을 읽고 요청에 맞게 답해 주세요. 별도의 요청이 없으면 문제의 답과 풀이를 한국어로 제공해 주세요."),
            .image("data:image/png;base64,\(imageData.base64EncodedString())")
        ], limit: credential.mode == .apiKey ? 2200 : nil, effort: reasoningEffort)
        return try await perform(payload: payload, credential: credential, onProgress: onProgress)
    }

    func explain(selectedText: String, credential: InferenceCredential, model: String,
                 reasoningEffort: String? = nil,
                 onProgress: (@Sendable (InferenceProgressEvent) -> Void)? = nil,
                 imageData: Data? = nil, additionalInstructions: String = "") async throws -> String {
        guard !model.isEmpty else { throw OpenAIServiceError.invalidModel }
        let content = try Self.inputContent(text: selectedText, instructions: additionalInstructions, image: imageData, model: model)
        let payload = makeRequest(model: model, instructions: Self.instructions, content: content,
                                  limit: credential.mode == .apiKey ? 2200 : nil, effort: reasoningEffort)
        return try await perform(payload: payload, credential: credential, onProgress: onProgress)
    }

    private func makeRequest(model: String, instructions: String, content: [InputContent], limit: Int?, effort: String?) -> ResponseRequest {
        ResponseRequest(model: model, instructions: instructions,
                        input: [.init(role: "user", content: content)], maxOutputTokens: limit,
                        store: false, stream: true,
                        reasoning: ModelCapabilities.validatedEffort(effort, model: model).map { .init(effort: $0) })
    }

    private static func inputContent(text: String, instructions: String, image: Data?, model: String) throws -> [InputContent] {
        try InputAttachment.validate(text: text, additionalInstructions: instructions)
        var content: [InputContent] = [.text(text)]
        if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.append(.text("추가 지시:\n" + instructions))
        }
        if let image {
            try InputAttachment.validate(image: image, model: model)
            content.append(.image("data:image/png;base64,\(image.base64EncodedString())"))
        }
        return content
    }

    func listChatGPTModels(accessToken: String) async throws -> [ChatGPTModel] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIServiceError.invalidResponse }
        guard http.statusCode == 200 else { throw Self.apiError(data: data, status: http.statusCode) }
        let catalogue = try JSONDecoder().decode(ChatGPTModelCatalogue.self, from: data)
        return catalogue.models.filter { $0.visibility == "list" }
    }

    func generateCode(selectedText: String, language: String, credential: InferenceCredential, model: String,
                      reasoningEffort: String? = nil,
                      onProgress: (@Sendable (InferenceProgressEvent) -> Void)? = nil,
                      imageData: Data? = nil, additionalInstructions: String = "") async throws -> String {
        guard !model.isEmpty else { throw OpenAIServiceError.invalidModel }
        let content = try Self.inputContent(text: selectedText, instructions: additionalInstructions, image: imageData, model: model)
        let payload = makeRequest(model: model, instructions: Self.codeInstructions(language: language), content: content,
                                  limit: credential.mode == .apiKey ? 12000 : nil, effort: reasoningEffort)
        return try await perform(payload: payload, credential: credential, onProgress: onProgress)
    }

    static func codeInstructions(language: String) -> String {
        instructions + "\n" + """
        이번 작업은 선택한 문제 또는 요청을 완성된 코드로 작성하는 것이다. 사용자가 본문에서 코드 언어를 지정하면 그 언어를 따르고, 지정하지 않으면 기본 언어 \(language)를 사용한다.
        제출·실행할 수 있는 전체 코드를 정확히 하나의 Markdown 코드 블록으로 출력한다. 여러 대안이나 예제 블록을 추가하지 않는다. 코드 밖 설명, 제목, 파일명은 출력하지 않는다. 코드의 줄바꿈과 들여쓰기를 유지한다.
        필요한 가정이 있으면 코드 주석에 명시한다. 정답을 결정하는 필수 정보가 없어 코드를 완성할 수 없으면 불완전하거나 임의로 지어낸 코드 대신 필요한 정보를 짧게 요청한다.
        """
    }

    private func perform(payload: ResponseRequest, credential: InferenceCredential,
                         onProgress: (@Sendable (InferenceProgressEvent) -> Void)?) async throws -> String {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)
        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw OpenAIServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                if data.count >= 65_536 { break }
                data.append(byte)
            }
            throw Self.apiError(data: data, status: http.statusCode)
        }
        if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
            var accumulator = ResponseStreamAccumulator()
            var frames = SSEEventFramer()
            var progress = ResponseProgressReporter()
            for try await byte in bytes {
                try Task.checkCancellation()
                if let event = try frames.append(byte) {
                    progress.observe(event, completedText: nil, notify: onProgress)
                    let completed = try accumulator.consume(event)
                    progress.observe(event, completedText: completed, notify: onProgress)
                    if let completed {
                        try Task.checkCancellation()
                        return completed
                    }
                }
            }
            if let event = try frames.finish() {
                progress.observe(event, completedText: nil, notify: onProgress)
                let completed = try accumulator.consume(event)
                progress.observe(event, completedText: completed, notify: onProgress)
                if let completed { try Task.checkCancellation(); return completed }
            }
            throw OpenAIServiceError.interruptedStream
        }
        // Some compatible transports return a complete JSON response despite stream=true.
        // This path reports no SSE event and first text only when the body is available.
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 20 * 1024 * 1024 else { throw OpenAIServiceError.invalidResponse }
            data.append(byte)
        }
        let decoded = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        guard decoded.status == "completed" else { throw OpenAIServiceError.interruptedStream }
        let text = decoded.output.filter { $0.type == "message" }.flatMap(\.content)
            .filter { $0.type == "output_text" }.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenAIServiceError.emptyOutput }
        try Task.checkCancellation()
        onProgress?(.firstText)
        onProgress?(.completed)
        return text
    }

    static func apiError(data: Data, status: Int) -> OpenAIServiceError {
        let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = envelope?.error.code
        let message: String
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            message = "이 앱 또는 ChatGPT 구독의 사용 한도에 도달했습니다. ChatGPT 사용량 설정을 확인해 주세요."
        case "subscription_sharing_user_not_eligible":
            message = "현재 계정·워크스페이스에서는 구독 연동을 사용할 수 없습니다."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            message = "현재 구독 사용량을 확인할 수 없습니다. 잠시 후 다시 시도해 주세요."
        default:
            message = envelope?.error.message ?? object?["detail"] as? String ?? "요청이 실패했습니다."
        }
        return .api(status: status, message: code.map { "\(message) [\($0)]" } ?? message)
    }

    static let instructions = """
    당신은 사용자가 선택한 텍스트나 화면 이미지에 대해 답하는 개인 학습 도우미다.
    사용자의 명시적인 요청에 맞춰 답한다. 선택한 본문 끝에 덧붙인 요청도 사용자의 요청으로 취급한다.
    설명을 요청하면 설명을, 요약이나 번역을 요청하면 해당 결과를, 코드를 요청하면 지정한 언어의 완성된 코드를 제공한다. 코드만 요청하면 코드만 답한다. 요청한 결과를 먼저 제시하고 필요한 설명을 덧붙인다.
    별도의 요청이 없으면 질문이나 문제에는 답과 풀이를, 개념이나 문단에는 핵심 설명을 제공한다. 기본 답변 언어는 한국어지만 사용자가 지정한 언어와 형식을 따른다. 고정된 목차나 튜터 형식을 강요하지 않는다.
    그림 파일명만 있고 실제 그림이 없어도 제공된 조건으로 답할 수 있는 부분은 바로 답한다. 누락된 그림 때문에 설명 전체를 보류하지 않는다. 불확실한 부분은 짧게 밝히고, 조건을 합리적으로 가정해 진행할 수 있으면 가정을 명시하고 요청한 결과를 제공한다. 확인하지 않은 그림의 내용이나 정답을 사실처럼 지어내지 않는다. 정확한 결과를 결정할 수 없고 가정으로도 해결할 수 없는 경우에만 꼭 필요한 정보 하나를 구체적으로 요청하며, 가능한 설명이나 접근법은 함께 제공한다.
    공개된 연습 문제나 과거 코딩테스트 문제라는 이유만으로 답이나 코드를 제한하지 않는다.
    이미지가 진행 중인 시험, 감독 화면, 제한 시간이 표시된 평가, 또는 부정행위 방지 안내로 보이면 정답이나 제출용 코드를 제공하지 않는다. 대신 해당 주제의 일반 개념을 복습하는 방법만 제시한다. 자동 입력·은닉·감독 회피를 돕는 내용은 제공하지 않는다.
    """
}

/// AsyncBytes.lines skips empty lines, which are SSE frame boundaries.
/// Parse raw bytes to retain boundaries, including CRLF and split UTF-8 characters.
struct SSEEventFramer {
    private var line = Data()
    private var fields: [String] = []
    private var previousCR = false
    private var frameSize = 0

    mutating func append(_ byte: UInt8) throws -> String? {
        if previousCR {
            previousCR = false
            if byte == 10 { return nil }
        }
        if byte == 10 || byte == 13 {
            previousCR = byte == 13
            return try endLine()
        }
        guard line.count < 2_097_152 else { throw OpenAIServiceError.invalidResponse }
        line.append(byte)
        return nil
    }

    mutating func finish() throws -> String? {
        if !line.isEmpty { _ = try endLine() }
        guard !fields.isEmpty else { return nil }
        defer { fields.removeAll(); frameSize = 0 }
        return fields.joined(separator: "\n")
    }

    private mutating func endLine() throws -> String? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !fields.isEmpty else { return nil }
            defer { fields.removeAll(); frameSize = 0 }
            return fields.joined(separator: "\n")
        }
        let value = String(decoding: line, as: UTF8.self)
        if value.hasPrefix("data:") {
            var data = String(value.dropFirst(5))
            if data.hasPrefix(" ") { data.removeFirst() }
            frameSize += data.utf8.count
            guard frameSize <= 2_097_152 else { throw OpenAIServiceError.invalidResponse }
            fields.append(data)
        }
        return nil
    }
}

struct InferenceCredential {
    let token: String
    let mode: BillingMode
}

struct ChatGPTModel: Decodable, Identifiable {
    var id: String { slug }
    let slug: String
    let displayName: String
    let visibility: String?
    enum CodingKeys: String, CodingKey { case slug, displayName = "display_name", visibility }
}

private struct ChatGPTModelCatalogue: Decodable { let models: [ChatGPTModel] }

struct ResponseRequest: Encodable {
    let model: String
    let instructions: String
    let input: [InputMessage]
    let maxOutputTokens: Int?
    let store: Bool
    let stream: Bool
    var reasoning: Reasoning? = nil
    struct Reasoning: Encodable { let effort: String }

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, store, stream, reasoning
        case maxOutputTokens = "max_output_tokens"
    }
}

struct InputMessage: Encodable {
    let role: String
    let content: [InputContent]
}

enum InputContent: Encodable {
    case text(String)
    case image(String)

    enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url", detail }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("input_text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let imageURL):
            try container.encode("input_image", forKey: .type)
            try container.encode(imageURL, forKey: .imageURL)
            try container.encode("high", forKey: .detail)
        }
    }
}

private struct ResponseEnvelope: Decodable {
    let status: String?
    let output: [OutputItem]
}

private struct OutputItem: Decodable {
    let type: String
    let content: [OutputContent]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        content = try container.decodeIfPresent([OutputContent].self, forKey: .content) ?? []
    }

    enum CodingKeys: String, CodingKey { case type, content }
}

private struct OutputContent: Decodable {
    let type: String
    let text: String?
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String?; let code: String? }
    let error: APIError
}

/// Partial output is not success: require the terminal completion event.
struct ResponseStreamAccumulator {
    private var text = ""

    mutating func consume(_ eventData: String) throws -> String? {
        if eventData == "[DONE]" { return nil }
        guard let data = eventData.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { throw OpenAIServiceError.invalidResponse }
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            text += event["delta"] as? String ?? ""
        case "response.completed":
            let response = event["response"] as? [String: Any]
            guard response?["status"] as? String == "completed" else { throw OpenAIServiceError.interruptedStream }
            if text.isEmpty, let output = response?["output"] as? [[String: Any]] {
                text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                    .compactMap { $0["text"] as? String ?? $0["refusal"] as? String }
                    .joined(separator: "\n")
            }
            let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else { throw OpenAIServiceError.emptyOutput }
            return result
        case "response.failed", "error":
            let response = event["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any] ?? event["error"] as? [String: Any] ?? event
            let body = try JSONSerialization.data(withJSONObject: ["error": error])
            throw OpenAIService.apiError(data: body, status: error["code"] as? String == "subscription_sharing_usage_limit_exceeded" ? 429 : 503)
        case "response.incomplete":
            throw OpenAIServiceError.interruptedStream
        default: break
        }
        return nil
    }
}


enum InferenceProgressEvent: Equatable, Sendable { case firstEvent, firstText, completed }

struct ResponseProgressReporter {
    private var sawEvent = false
    private var sawText = false

    mutating func observe(_ data: String, completedText: String?, notify: (@Sendable (InferenceProgressEvent) -> Void)?) {
        guard data != "[DONE]", let bytes = data.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let type = event["type"] as? String else { return }
        if !sawEvent { sawEvent = true; notify?(.firstEvent) }
        let textDelta = ["response.output_text.delta", "response.refusal.delta"].contains(type)
            && !(event["delta"] as? String ?? "").isEmpty
        if !sawText, textDelta || !(completedText ?? "").isEmpty { sawText = true; notify?(.firstText) }
        if completedText != nil { notify?(.completed) }
    }
}
