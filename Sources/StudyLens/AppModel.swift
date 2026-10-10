import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case selecting
        case analyzing
        case ready
        case failed

        var symbolName: String {
            switch self {
            case .idle: return "graduationcap"
            case .selecting: return "viewfinder"
            case .analyzing: return "sparkles"
            case .ready: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }

        var menuTitle: String {
            switch self {
            case .idle: return "StudyLens"
            case .selecting: return "영역 선택 중"
            case .analyzing: return "설명 작성 중"
            case .ready: return "설명 준비됨"
            case .failed: return "확인 필요"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var explanation = ""
    @Published private(set) var capturedImage: NSImage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasSelectionError = false
    @Published private(set) var copied = false
    @Published private(set) var copiedCodeID: Int?
    @Published private(set) var quickCopyMessage: String?
    @Published private(set) var shortcutError: String?
    var responseDocument: ResponseDocument { ResponseDocument(explanation) }
    @Published var captureShortcut: HotKeyConfiguration {
        didSet {
            guard captureShortcut != oldValue else { return }
            captureShortcut.save(prefix: "capture")
            registerHotKeys()
        }
    }
    @Published var textShortcut: HotKeyConfiguration {
        didSet {
            guard textShortcut != oldValue else { return }
            textShortcut.save(prefix: "text")
            registerHotKeys()
        }
    }
    @Published var codeShortcut: HotKeyConfiguration {
        didSet {
            guard codeShortcut != oldValue else { return }
            codeShortcut.save(prefix: "code")
            registerHotKeys()
        }
    }
    @Published var codeLanguage: String {
        didSet { UserDefaults.standard.set(codeLanguage, forKey: "codeLanguage") }
    }
    @Published var modelName: String {
        didSet { UserDefaults.standard.set(modelName, forKey: Self.modelKey) }
    }
    @Published var billingMode: BillingMode {
        didSet { UserDefaults.standard.set(billingMode.rawValue, forKey: "billingMode") }
    }
    @Published var chatGPTModelName: String {
        didSet { UserDefaults.standard.set(chatGPTModelName, forKey: "chatGPTModelName") }
    }
    @Published var claudeModelName: String {
        didSet { UserDefaults.standard.set(claudeModelName, forKey: "claudeModelName") }
    }
    @Published var claudeExecutablePath: String {
        didSet { UserDefaults.standard.set(claudeExecutablePath, forKey: "claudeExecutablePath") }
    }
    @Published private(set) var claudeStatus: ClaudeCodeStatus?
    @Published private(set) var chatGPTProfiles: [ChatGPTProfile] = []
    @Published private(set) var activeChatGPTClientID = ""
    @Published private(set) var chatGPTModels: [ChatGPTModel] = []
    @Published private(set) var connectionBusy = false
    @Published private(set) var connectionMessage: String?
    @Published var showPlanWelcome = false
    private lazy var chatGPTAuth = ChatGPTAuthService()

    var activeChatGPTProfile: ChatGPTProfile? { chatGPTProfiles.first { $0.clientID == activeChatGPTClientID } }
    var billingLabel: String { billingMode.title }
    var isWorking: Bool { status == .selecting || status == .analyzing }
    @Published private(set) var resultBillingLabel = ""

    private static let modelKey = "openAIModel"
    private let hotKeyService = HotKeyService()
    private let captureService = ScreenCaptureService()
    private let selectedTextService = SelectedTextService()
    private let openAIService = OpenAIService()
    private let claudeCodeService = ClaudeCodeService()
    private var claudeLoginTask: Task<Void, Error>?
    private var started = false

    init(startServices: Bool = true) {
        captureShortcut = HotKeyConfiguration.load(prefix: "capture", fallback: .captureDefault)
        textShortcut = HotKeyConfiguration.load(prefix: "text", fallback: .textDefault)
        codeShortcut = HotKeyConfiguration.load(prefix: "code", fallback: .codeDefault)
        codeLanguage = UserDefaults.standard.string(forKey: "codeLanguage") ?? "Java"
        modelName = UserDefaults.standard.string(forKey: Self.modelKey) ?? "gpt-4.1-mini"
        billingMode = UserDefaults.standard.string(forKey: "billingMode").flatMap(BillingMode.init(rawValue:)) ?? .chatGPT
        chatGPTModelName = UserDefaults.standard.string(forKey: "chatGPTModelName") ?? ""
        claudeModelName = UserDefaults.standard.string(forKey: "claudeModelName") ?? ""
        claudeExecutablePath = UserDefaults.standard.string(forKey: "claudeExecutablePath") ?? ""
        if startServices {
            syncChatGPTProfiles()
            start()
            if activeChatGPTProfile?.credentials?.permitsInference == true {
                Task { await refreshChatGPTModels() }
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        hotKeyService.onCaptureTrigger = { [weak self] in
            Task { @MainActor in
                await self?.captureAndAnalyze()
            }
        }
        hotKeyService.onTextTrigger = { [weak self] in
            Task { @MainActor in
                await self?.analyzeSelectedText()
            }
        }
        hotKeyService.onCodeTrigger = { [weak self] in
            Task { @MainActor in await self?.copySelectedCode() }
        }
        registerHotKeys()
    }

    func captureAndAnalyze() async {
        guard !isWorking, !connectionBusy else { return }
        hasSelectionError = false
        quickCopyMessage = nil
        copied = false
        copiedCodeID = nil
        errorMessage = nil
        explanation = ""
        capturedImage = nil
        selectedText = ""

        do {
            status = .selecting
            let route = try await inferenceRoute()
            resultBillingLabel = billingLabel
            let capture = try await captureService.captureInteractiveRegion()
            capturedImage = NSImage(data: capture)
            selectedText = ""
            status = .analyzing
            NotificationCenter.default.post(name: .studyLensOpenResult, object: nil)

            explanation = try await explain(imageData: capture, route: route)
            status = .ready
        } catch is CancellationError {
            status = .idle
        } catch let error as ScreenCaptureError where error == .cancelled {
            status = .idle
        } catch {
            fail(error.localizedDescription)
            NotificationCenter.default.post(name: .studyLensOpenResult, object: nil)
        }
    }

    @Published private(set) var selectedText = ""

    func analyzeSelectedText() async {
        guard !isWorking, !connectionBusy else { return }
        hasSelectionError = false
        quickCopyMessage = nil
        copied = false
        copiedCodeID = nil
        errorMessage = nil
        explanation = ""
        capturedImage = nil
        selectedText = ""

        do {
            // Read the selection before authentication or model discovery can change focus.
            status = .selecting
            let text = try await selectedTextService.readSelectedText()
            selectedText = text
            capturedImage = nil
            status = .analyzing
            let route = try await inferenceRoute()
            resultBillingLabel = billingLabel
            NotificationCenter.default.post(name: .studyLensOpenResult, object: nil)
            explanation = try await explain(selectedText: text, route: route)
            status = .ready
        } catch {
            hasSelectionError = error is SelectedTextError
            fail(error.localizedDescription)
            NotificationCenter.default.post(name: .studyLensOpenResult, object: nil)
        }
    }

    func copyExplanation() {
        guard (status == .ready || status == .failed), !explanation.isEmpty else { return }
        copied = ResponseClipboard.copy(explanation)
        copiedCodeID = nil
    }

    func copySelectedCode(using injectedWorkflow: QuickCodeCopy? = nil) async {
        guard !isWorking, !connectionBusy else { return }
        reset()
        quickCopyMessage = "선택한 텍스트 읽는 중…"
        status = .selecting
        NotificationCenter.default.post(name: .studyLensHideResult, object: nil)
        let language = codeLanguage
        let workflow = injectedWorkflow ?? QuickCodeCopy(
            readSelection: { [selectedTextService] in try await selectedTextService.readSelectedText(promptForPermission: false) },
            generate: { [self] text in
                let route = try await inferenceRoute()
                resultBillingLabel = billingLabel
                return try await generateCode(selectedText: text, language: language, route: route)
            }
        )
        do {
            copiedCodeID = try await workflow.run(onSelection: { [self] text in
                selectedText = text
                quickCopyMessage = "코드 작성 중… 완료되면 클립보드에 복사합니다."
                status = .analyzing
            }, onResponse: { [self] response in explanation = response })
            quickCopyMessage = "코드 복사 완료 · ⌘V로 붙여넣기"
            status = .ready
        } catch {
            hasSelectionError = error is SelectedTextError
            quickCopyMessage = "복사하지 못했습니다 · 메뉴에서 오류 확인"
            fail(error.localizedDescription)
        }
        // This workflow deliberately never posts studyLensOpenResult, even on failure.
    }

    func copyCode(_ id: Int) {
        guard status == .ready || status == .failed,
              let block = responseDocument.blocks.first(where: { $0.id == id && $0.isCode && $0.isComplete }),
              !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        copiedCodeID = ResponseClipboard.copy(block.text) ? id : nil
        copied = false
    }

    func restoreExplanation(_ text: String) {
        guard !isWorking, !text.isEmpty else { return }
        reset()
        explanation = text
        status = .ready
    }

    func reset() {
        status = .idle
        hasSelectionError = false
        explanation = ""
        capturedImage = nil
        selectedText = ""
        errorMessage = nil
        copied = false
        copiedCodeID = nil
        quickCopyMessage = nil
    }

    func saveAPIKey(_ value: String) throws {
        try KeychainService.saveAPIKey(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func loadAPIKey() -> String {
        (try? KeychainService.loadAPIKey()) ?? ""
    }

    func deleteAPIKey() throws {
        try KeychainService.deleteAPIKey()
    }

    private func fail(_ message: String) {
        status = .failed
        errorMessage = message
    }

    private func registerHotKeys() {
        guard started else { return }
        let errors = hotKeyService.register(capture: captureShortcut, text: textShortcut, code: codeShortcut)
        shortcutError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private var currentModelName: String {
        (billingMode == .chatGPT ? chatGPTModelName : modelName).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum InferenceRoute {
        case openAI(InferenceCredential)
        case claudeCode
    }

    private func inferenceRoute() async throws -> InferenceRoute {
        guard billingMode == .claudeCode else { return .openAI(try await inferenceCredential()) }
        let path = claudeExecutablePath
        _ = try await Task.detached { try ClaudeCodeService.locateExecutable(override: path) }.value
        return .claudeCode
    }

    private func explain(imageData: Data, route: InferenceRoute) async throws -> String {
        switch route {
        case .openAI(let credential):
            return try await openAIService.explain(imageData: imageData, credential: credential, model: currentModelName)
        case .claudeCode:
            return try await claudeCodeService.explain(imageData: imageData, executablePath: claudeExecutablePath, model: claudeModelName)
        }
    }

    private func explain(selectedText: String, route: InferenceRoute) async throws -> String {
        switch route {
        case .openAI(let credential):
            return try await openAIService.explain(selectedText: selectedText, credential: credential, model: currentModelName)
        case .claudeCode:
            return try await claudeCodeService.explain(selectedText: selectedText, executablePath: claudeExecutablePath, model: claudeModelName)
        }
    }

    private func generateCode(selectedText: String, language: String, route: InferenceRoute) async throws -> String {
        switch route {
        case .openAI(let credential):
            return try await openAIService.generateCode(selectedText: selectedText, language: language, credential: credential, model: currentModelName)
        case .claudeCode:
            return try await claudeCodeService.generateCode(selectedText: selectedText, language: language, executablePath: claudeExecutablePath, model: claudeModelName)
        }
    }

    private func inferenceCredential() async throws -> InferenceCredential {
        if billingMode == .apiKey {
            let key = try KeychainService.loadAPIKey()
            guard !key.isEmpty else { throw ChatGPTAuthError.oauth("API 키가 저장되지 않았습니다") }
            return .init(token: key, mode: .apiKey)
        }
        let token = try await chatGPTAuth.accessToken()
        syncChatGPTProfiles()
        if chatGPTModels.isEmpty { try await loadChatGPTModels(token: token) }
        guard chatGPTModels.contains(where: { $0.slug == chatGPTModelName }) else {
            throw OpenAIServiceError.invalidModel
        }
        return .init(token: token, mode: .chatGPT)
    }

    func signInWithChatGPT(newAccount: Bool = false, requestConsent: Bool = false) async {
        guard !connectionBusy, !isWorking else { return }
        connectionBusy = true
        connectionMessage = "브라우저에서 ChatGPT 로그인과 구독 사용 권한을 확인해 주세요."
        defer { connectionBusy = false; syncChatGPTProfiles() }
        do {
            try await chatGPTAuth.signIn(newAccount: newAccount, requestConsent: requestConsent)
            syncChatGPTProfiles()
            chatGPTModels = []
            if activeChatGPTProfile?.credentials?.permitsInference == true {
                billingMode = .chatGPT
                let token = try await chatGPTAuth.accessToken()
                try await loadChatGPTModels(token: token)
                connectionMessage = "ChatGPT 구독 사용이 연결되었습니다."
                if !UserDefaults.standard.bool(forKey: "chatGPTWelcomeShown") {
                    UserDefaults.standard.set(true, forKey: "chatGPTWelcomeShown")
                    showPlanWelcome = true
                }
            } else {
                connectionMessage = "로그인은 완료되었지만 구독 사용 권한이 없습니다. 구독 사용 허용을 눌러 주세요."
            }
        } catch { connectionMessage = error.localizedDescription }
    }

    func cancelChatGPTSignIn() { chatGPTAuth.cancelSignIn() }

    func selectChatGPTProfile(_ clientID: String) async {
        guard !connectionBusy, !isWorking else { return }
        do {
            try chatGPTAuth.selectProfile(clientID)
            syncChatGPTProfiles()
            chatGPTModels = []
            await refreshChatGPTModels()
        } catch { connectionMessage = error.localizedDescription }
    }

    func refreshChatGPTModels() async {
        guard !connectionBusy else { return }
        connectionBusy = true
        defer { connectionBusy = false; syncChatGPTProfiles() }
        do {
            let token = try await chatGPTAuth.accessToken()
            try await loadChatGPTModels(token: token)
            connectionMessage = nil
        } catch { connectionMessage = error.localizedDescription }
    }

    private func loadChatGPTModels(token: String) async throws {
        chatGPTModels = try await openAIService.listChatGPTModels(accessToken: token)
        guard !chatGPTModels.isEmpty else { throw OpenAIServiceError.invalidModel }
        if !chatGPTModels.contains(where: { $0.slug == chatGPTModelName }) {
            chatGPTModelName = chatGPTModels[0].slug
        }
    }

    func signOutOfChatGPT() async {
        guard !connectionBusy, !isWorking else { return }
        connectionBusy = true
        defer { connectionBusy = false; syncChatGPTProfiles() }
        do {
            let revoked = try await chatGPTAuth.signOut()
            chatGPTModels = []
            connectionMessage = revoked ? "ChatGPT 연결에서 로그아웃했습니다." : "앱에서 로그아웃했습니다. 서버의 연결 해제는 확인하지 못했으니 ChatGPT 설정에서도 연결을 해제해 주세요."
        } catch { connectionMessage = error.localizedDescription }
    }

    func refreshClaudeStatus() async {
        guard !connectionBusy else { return }
        connectionBusy = true
        defer { connectionBusy = false }
        do {
            claudeStatus = try await claudeCodeService.status(executablePath: claudeExecutablePath)
            connectionMessage = claudeStatus?.loggedIn == true ? nil : ClaudeCodeError.notLoggedIn.localizedDescription
        } catch {
            claudeStatus = nil
            connectionMessage = error.localizedDescription
        }
    }

    func signInWithClaude() async {
        guard !connectionBusy, !isWorking else { return }
        connectionBusy = true
        connectionMessage = "브라우저에서 Claude 로그인을 완료해 주세요. Claude Code가 로그인을 처리합니다."
        let path = claudeExecutablePath
        let task = Task { [claudeCodeService] in try await claudeCodeService.login(executablePath: path) }
        claudeLoginTask = task
        do {
            try await task.value
            claudeLoginTask = nil
            connectionBusy = false
            await refreshClaudeStatus()
            if claudeStatus?.loggedIn == true { connectionMessage = "Claude 구독 사용이 연결되었습니다." }
        } catch {
            claudeLoginTask = nil
            connectionBusy = false
            connectionMessage = error is CancellationError ? "로그인을 취소했습니다." : error.localizedDescription
        }
    }

    func cancelClaudeSignIn() { claudeLoginTask?.cancel() }

    private func syncChatGPTProfiles() {
        chatGPTProfiles = chatGPTAuth.profiles
        activeChatGPTClientID = chatGPTAuth.activeClientID ?? ""
    }
}

extension Notification.Name {
    static let studyLensOpenResult = Notification.Name("StudyLens.openResult")
    static let studyLensHideResult = Notification.Name("StudyLens.hideResult")
}
