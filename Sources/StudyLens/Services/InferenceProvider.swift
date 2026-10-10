import Foundation

/// A backend that answers the three StudyLens requests. AppModel builds one per request
/// from the selected billing mode, so new backends only need to conform here.
protocol InferenceProvider {
    func explain(imageData: Data) async throws -> String
    func explain(selectedText: String) async throws -> String
    func generateCode(selectedText: String, language: String) async throws -> String
}

/// OpenAI Responses API with a credential resolved for this request (ChatGPT plan or API key).
struct OpenAIProvider: InferenceProvider {
    let service: OpenAIService
    let credential: InferenceCredential
    let model: String

    func explain(imageData: Data) async throws -> String {
        try await service.explain(imageData: imageData, credential: credential, model: model)
    }

    func explain(selectedText: String) async throws -> String {
        try await service.explain(selectedText: selectedText, credential: credential, model: model)
    }

    func generateCode(selectedText: String, language: String) async throws -> String {
        try await service.generateCode(selectedText: selectedText, language: language, credential: credential, model: model)
    }
}

/// Prompts shared by every provider so answers behave the same regardless of backend.
enum StudyPrompt {
    static let imageRequest = "화면 이미지의 내용과 사용자의 요청을 읽고 요청에 맞게 답해 주세요. 별도의 요청이 없으면 문제의 답과 풀이를 한국어로 제공해 주세요."

    static let instructions = """
    당신은 사용자가 선택한 텍스트나 화면 이미지에 대해 답하는 개인 학습 도우미다.
    사용자의 명시적인 요청에 맞춰 답한다. 선택한 본문 끝에 덧붙인 요청도 사용자의 요청으로 취급한다.
    설명을 요청하면 설명을, 요약이나 번역을 요청하면 해당 결과를, 코드를 요청하면 지정한 언어의 완성된 코드를 제공한다. 코드만 요청하면 코드만 답한다. 요청한 결과를 먼저 제시하고 필요한 설명을 덧붙인다.
    별도의 요청이 없으면 질문이나 문제에는 답과 풀이를, 개념이나 문단에는 핵심 설명을 제공한다. 기본 답변 언어는 한국어지만 사용자가 지정한 언어와 형식을 따른다. 고정된 목차나 튜터 형식을 강요하지 않는다.
    그림 파일명만 있고 실제 그림이 없어도 제공된 조건으로 답할 수 있는 부분은 바로 답한다. 누락된 그림 때문에 설명 전체를 보류하지 않는다. 불확실한 부분은 짧게 밝히고, 조건을 합리적으로 가정해 진행할 수 있으면 가정을 명시하고 요청한 결과를 제공한다. 확인하지 않은 그림의 내용이나 정답을 사실처럼 지어내지 않는다. 정확한 결과를 결정할 수 없고 가정으로도 해결할 수 없는 경우에만 꼭 필요한 정보 하나를 구체적으로 요청하며, 가능한 설명이나 접근법은 함께 제공한다.
    공개된 연습 문제나 과거 코딩테스트 문제라는 이유만으로 답이나 코드를 제한하지 않는다.
    이미지가 진행 중인 시험, 감독 화면, 제한 시간이 표시된 평가, 또는 부정행위 방지 안내로 보이면 정답이나 제출용 코드를 제공하지 않는다. 대신 해당 주제의 일반 개념을 복습하는 방법만 제시한다. 자동 입력·은닉·감독 회피를 돕는 내용은 제공하지 않는다.
    """

    static func codeInstructions(language: String) -> String {
        instructions + "\n" + """
        이번 작업은 선택한 문제 또는 요청을 완성된 코드로 작성하는 것이다. 사용자가 본문에서 코드 언어를 지정하면 그 언어를 따르고, 지정하지 않으면 기본 언어 \(language)를 사용한다.
        제출·실행할 수 있는 전체 코드를 정확히 하나의 Markdown 코드 블록으로 출력한다. 여러 대안이나 예제 블록을 추가하지 않는다. 코드 밖 설명, 제목, 파일명은 출력하지 않는다. 코드의 줄바꿈과 들여쓰기를 유지한다.
        필요한 가정이 있으면 코드 주석에 명시한다. 정답을 결정하는 필수 정보가 없어 코드를 완성할 수 없으면 불완전하거나 임의로 지어낸 코드 대신 필요한 정보를 짧게 요청한다.
        """
    }
}
