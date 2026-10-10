import Foundation

/// In-memory timings only. No input, output, or authentication data belongs here.
struct RequestProgress {
    enum Stage: String {
        case readingSelection, selectingImage, preparingConnection, waiting, generating, copying
        case completed, cancelled, failed

        var title: String {
            switch self {
            case .readingSelection: return "선택 텍스트 읽는 중"
            case .selectingImage: return "그림 영역 선택 중"
            case .preparingConnection: return "연결 준비 중"
            case .waiting: return "응답 대기 중"
            case .generating: return "응답 작성 중"
            case .copying: return "코드 복사 중"
            case .completed: return "완료"
            case .cancelled: return "취소됨"
            case .failed: return "실패"
            }
        }
    }

    let startedAt: TimeInterval
    var stage: Stage
    var model: String
    let billingMode: BillingMode
    let effort: String?
    private(set) var selectionDuration: TimeInterval?
    private(set) var connectionDuration: TimeInterval?
    private(set) var firstEvent: TimeInterval?
    private(set) var firstText: TimeInterval?
    private(set) var responseCompleted: TimeInterval?
    private(set) var endedAt: TimeInterval?
    private var connectionStartedAt: TimeInterval?

    init(stage: Stage, model: String, billingMode: BillingMode, effort: String?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        startedAt = now
        self.stage = stage
        self.model = model
        self.billingMode = billingMode
        self.effort = effort
    }

    mutating func finishSelection(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        selectionDuration = max(0, now - startedAt)
    }

    mutating func prepareConnection(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        stage = .preparingConnection
        connectionStartedAt = now
    }

    mutating func waitForResponse(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        connectionDuration = connectionStartedAt.map { max(0, now - $0) }
        stage = .waiting
    }

    mutating func record(_ event: InferenceProgressEvent, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let elapsed = max(0, now - startedAt)
        switch event {
        case .firstEvent: if firstEvent == nil { firstEvent = elapsed }
        case .firstText:
            if firstText == nil { firstText = elapsed }
            if endedAt == nil { stage = .generating }
        case .completed: responseCompleted = min(responseCompleted ?? elapsed, elapsed)
        }
    }

    mutating func finish(_ stage: Stage, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.stage = stage
        endedAt = now
    }

    func elapsed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        max(0, (endedAt ?? now) - startedAt)
    }

    var diagnostics: String {
        var lines = ["모델: \(model) · 강도: \(effort ?? "모델 기본값") · \(billingMode.title)"]
        for (label, value) in [("선택 읽기", selectionDuration), ("인증·모델 확인", connectionDuration), ("첫 SSE 이벤트 (시작 후)", firstEvent), ("첫 출력 (시작 후)", firstText), ("응답 완료 (시작 후)", responseCompleted)] {
            if let value { lines.append("\(label): \(String(format: "%.2f", value))초") }
        }
        return lines.joined(separator: "\n")
    }
}
