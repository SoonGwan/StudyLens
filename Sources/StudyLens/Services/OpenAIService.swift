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

    func explain(imageData: Data, credential: InferenceCredential, model: String) async throws -> String {
        guard !model.isEmpty else { throw OpenAIServiceError.invalidModel }

        let imageURL = "data:image/png;base64,\(imageData.base64EncodedString())"
        let payload = ResponseRequest(
            model: model,
            instructions: StudyPrompt.instructions,
            input: [
                .init(role: "user", content: [
                    .text(StudyPrompt.imageRequest),
                    .image(imageURL)
                ])
            ],
            maxOutputTokens: credential.mode == .apiKey ? 2200 : nil,
            store: false,
            stream: credential.mode == .chatGPT
        )
        return try await perform(payload: payload, credential: credential)
    }

    func explain(selectedText: String, credential: InferenceCredential, model: String) async throws -> String {
        guard !model.isEmpty else { throw OpenAIServiceError.invalidModel }
        let payload = ResponseRequest(
            model: model,
            instructions: StudyPrompt.instructions,
            input: [
                .init(role: "user", content: [
                    .text(selectedText)
                ])
            ],
            maxOutputTokens: credential.mode == .apiKey ? 2200 : nil,
            store: false,
            stream: credential.mode == .chatGPT
        )
        return try await perform(payload: payload, credential: credential)
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

    func generateCode(selectedText: String, language: String, credential: InferenceCredential, model: String) async throws -> String {
        guard !model.isEmpty else { throw OpenAIServiceError.invalidModel }
        let payload = ResponseRequest(
            model: model,
            instructions: StudyPrompt.codeInstructions(language: language),
            input: [.init(role: "user", content: [.text(selectedText)])],
            maxOutputTokens: credential.mode == .apiKey ? 12000 : nil,
            store: false,
            stream: credential.mode == .chatGPT
        )
        return try await perform(payload: payload, credential: credential)
    }

    private func perform(payload: ResponseRequest, credential: InferenceCredential) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        if payload.stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw OpenAIServiceError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes {
                    if data.count >= 65_536 { break }
                    data.append(byte)
                }
                throw Self.apiError(data: data, status: http.statusCode)
            }
            var stream = ResponseStreamAccumulator()
            var frames = SSEEventFramer()
            for try await byte in bytes {
                if let event = try frames.append(byte), let completed = try stream.consume(event) { return completed }
            }
            if let event = try frames.finish(), let completed = try stream.consume(event) { return completed }
            throw OpenAIServiceError.interruptedStream
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.apiError(data: data, status: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        if let status = decoded.status, status != "completed" { throw OpenAIServiceError.interruptedStream }
        let text = decoded.output
            .filter { $0.type == "message" }
            .flatMap(\.content)
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw OpenAIServiceError.emptyOutput }
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

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, store, stream
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
