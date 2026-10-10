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
    @Published private(set) var hasInputError = false
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
    private let openAIService: OpenAIService
    private let selectionReader: ((Bool) async throws -> String)?
    private let imageCapturer: ((Bool) async throws -> Data)?
    private let credentialProvider: ((BillingMode, String) async throws -> InferenceCredential)?
    private let clipboardWriter: (String) -> Bool
    private var activeRequestID: UUID?
    private var progressRequestID: UUID?
    private var activeRequestTask: Task<Void, Never>?
    @Published private(set) var requestProgress: RequestProgress?
    @Published var attachImageToSelection: Bool {
        didSet { UserDefaults.standard.set(attachImageToSelection, forKey: "attachImageToSelection") }
    }
    @Published var additionalInstructions: String {
        didSet { UserDefaults.standard.set(additionalInstructions, forKey: "additionalInstructions") }
    }
    private let reasoningSettings: ReasoningSettings
    var reasoningPreference: ReasoningPreference {
        get { reasoningSettings.preference(model: currentModelName, mode: billingMode) }
        set {
            guard !isWorking else { return }
            objectWillChange.send()
            reasoningSettings.set(newValue, model: currentModelName, mode: billingMode)
        }
    }
    var selectedReasoningEffort: String? {
        ModelCapabilities.validatedEffort(reasoningPreference.rawValue, model: currentModelName)
    }

    private struct RequestOptions {
        let mode: BillingMode
        let model: String
        let language: String
        let effort: String?
        let attachImage: Bool
        let additionalInstructions: String
        let claudeExecutablePath: String
    }

    private var requestOptions: RequestOptions {
        .init(mode: billingMode, model: currentModelName, language: codeLanguage,
              effort: selectedReasoningEffort, attachImage: attachImageToSelection && billingMode != .claudeCode,
              additionalInstructions: additionalInstructions, claudeExecutablePath: claudeExecutablePath)
    }
    private var claudeLoginTask: Task<Void, Error>?
    private var started = false

    init(startServices: Bool = true, openAIService: OpenAIService = OpenAIService(),
         reasoningSettings: ReasoningSettings = ReasoningSettings(),
         selectionReader: ((Bool) async throws -> String)? = nil,
         imageCapturer: ((Bool) async throws -> Data)? = nil,
         credentialProvider: ((BillingMode, String) async throws -> InferenceCredential)? = nil,
         clipboardWriter: ((String) -> Bool)? = nil) {
        self.openAIService = openAIService
        self.reasoningSettings = reasoningSettings
        self.selectionReader = selectionReader
        self.imageCapturer = imageCapturer
        self.credentialProvider = credentialProvider
        self.clipboardWriter = clipboardWriter ?? { ResponseClipboard.copy($0) }
        attachImageToSelection = UserDefaults.standard.bool(forKey: "attachImageToSelection")
        additionalInstructions = UserDefaults.standard.string(forKey: "additionalInstructions") ?? ""
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

    @Published private(set) var selectedText = ""

    func captureAndAnalyze() async {
        await runRequest(initialStage: .selectingImage, silent: false) { id, options in
            let capture = try await self.captureImage(promptForPermission: true)
            try self.checkRequest(id)
            self.capturedImage = NSImage(data: capture)
            self.requestProgress?.prepareConnection()
            let provider = try await self.inferenceProvider(options: options, id: id)
            try self.checkRequest(id)
            self.beginInference(id: id, options: options, silent: false)
            let response = try await provider.explain(imageData: capture)
            try self.checkRequest(id)
            self.explanation = response
        }
    }

    func analyzeSelectedText(attachImage: Bool? = nil) async {
        await runRequest(initialStage: .readingSelection, silent: false, attachImage: attachImage) { id, options in
            let text = try await self.readSelection(promptForPermission: true)
            try self.checkRequest(id)
            self.selectedText = text
            try InputAttachment.validate(text: text, additionalInstructions: options.additionalInstructions)
            self.requestProgress?.finishSelection()
            // Keep the source selection before authentication, capture, or UI activation changes focus.
            let image = try await self.optionalImage(id: id, options: options, silent: false)
            self.requestProgress?.prepareConnection()
            let provider = try await self.inferenceProvider(options: options, id: id, image: image)
            try self.checkRequest(id)
            self.beginInference(id: id, options: options, silent: false)
            let response = try await provider.explain(selectedText: text)
            try self.checkRequest(id)
            self.explanation = response
        }
    }

    func copyExplanation() {
        guard (status == .ready || status == .failed), !explanation.isEmpty else { return }
        copied = clipboardWriter(explanation)
        copiedCodeID = nil
    }

    func copySelectedCode(using injectedWorkflow: QuickCodeCopy? = nil, attachImage: Bool? = nil) async {
        await runRequest(initialStage: .readingSelection, silent: true, attachImage: attachImage) { id, options in
            let workflow = injectedWorkflow ?? QuickCodeCopy(
                readSelection: { try await self.readSelection(promptForPermission: false) },
                generate: { text in
                    try InputAttachment.validate(text: text, additionalInstructions: options.additionalInstructions)
                    let image = try await self.optionalImage(id: id, options: options, silent: true)
                    self.requestProgress?.prepareConnection()
                    let provider = try await self.inferenceProvider(options: options, id: id, image: image)
                    try self.checkRequest(id)
                    self.beginInference(id: id, options: options, silent: true)
                    return try await provider.generateCode(selectedText: text, language: options.language)
                }, write: self.clipboardWriter
            )
            let codeID = try await workflow.run(onSelection: { text in
                guard self.activeRequestID == id else { return }
                self.selectedText = text
                self.requestProgress?.finishSelection()
                self.status = .analyzing
                self.quickCopyMessage = "코드 작성 중… 완료되면 클립보드에 복사합니다."
            }, onResponse: { response in
                guard self.activeRequestID == id else { return }
                self.explanation = response
                self.requestProgress?.stage = .copying
            }, canCommit: { self.activeRequestID == id })
            try self.checkRequest(id)
            self.copiedCodeID = codeID
            self.quickCopyMessage = "코드 복사 완료 · ⌘V로 붙여넣기"
        }
    }

    func cancelCurrentRequest() {
        guard activeRequestID != nil else { return }
        activeRequestID = nil // Fence late completions before allowing another request.
        progressRequestID = nil
        activeRequestTask?.cancel()
        activeRequestTask = nil
        requestProgress?.finish(.cancelled)
        status = .idle
        explanation = ""
        copiedCodeID = nil
        errorMessage = nil
        quickCopyMessage = "요청을 취소했습니다 · 기존 클립보드는 유지했습니다."
    }

    private func runRequest(initialStage: RequestProgress.Stage, silent: Bool, attachImage: Bool? = nil,
                            operation: @escaping (UUID, RequestOptions) async throws -> Void) async {
        guard !isWorking, !connectionBusy else { return }
        reset()
        let snapshot = requestOptions
        let options = RequestOptions(mode: snapshot.mode, model: snapshot.model, language: snapshot.language,
                                     effort: snapshot.effort, attachImage: attachImage ?? snapshot.attachImage,
                                     additionalInstructions: snapshot.additionalInstructions, claudeExecutablePath: snapshot.claudeExecutablePath)
        let id = UUID()
        activeRequestID = id
        progressRequestID = id
        requestProgress = .init(stage: initialStage, model: options.model, billingMode: options.mode, effort: options.effort)
        status = .selecting
        if silent {
            quickCopyMessage = "선택한 텍스트 읽는 중…"
            NotificationCenter.default.post(name: .studyLensHideResult, object: nil)
        }
        let task = Task { @MainActor [self] in
            defer {
                if activeRequestID == id { activeRequestID = nil; activeRequestTask = nil }
            }
            do {
                try await operation(id, options)
                try checkRequest(id)
                if options.mode == .claudeCode { requestProgress?.record(.firstText) }
                requestProgress?.record(.completed)
                requestProgress?.finish(.completed)
                status = .ready
            } catch {
                guard activeRequestID == id else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled ||
                    (error as? ScreenCaptureError) == .cancelled {
                    cancelCurrentRequest()
                    return
                }
                requestProgress?.finish(.failed)
                hasSelectionError = error is SelectedTextError
                hasInputError = hasSelectionError || error is ScreenCaptureError || error is InputValidationError
                if (error as? URLError)?.code == .timedOut {
                    fail("요청 시간이 초과되었습니다. 메뉴에서 직접 다시 요청해 주세요.")
                } else { fail(error.localizedDescription) }
                if silent { quickCopyMessage = "복사하지 못했습니다 · 메뉴에서 오류 확인" }
                else { NotificationCenter.default.post(name: .studyLensOpenResult, object: nil) }
            }
        }
        activeRequestTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }

    private func checkRequest(_ id: UUID) throws {
        try Task.checkCancellation()
        guard activeRequestID == id else { throw CancellationError() }
    }

    private func beginInference(id: UUID, options: RequestOptions, silent: Bool) {
        guard activeRequestID == id else { return }
        resultBillingLabel = options.mode.title
        status = .analyzing
        requestProgress?.waitForResponse()
        if !silent { NotificationCenter.default.post(name: .studyLensOpenResult, object: nil) }
    }

    private func progressHandler(id: UUID) -> @Sendable (InferenceProgressEvent) -> Void {
        { [weak self] event in
            let time = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self, self.progressRequestID == id else { return }
                self.requestProgress?.record(event, now: time)
            }
        }
    }

    private func readSelection(promptForPermission: Bool) async throws -> String {
        if let selectionReader { return try await selectionReader(promptForPermission) }
        return try await selectedTextService.readSelectedText(promptForPermission: promptForPermission)
    }

    private func captureImage(promptForPermission: Bool) async throws -> Data {
        if let imageCapturer { return try await imageCapturer(promptForPermission) }
        return try await captureService.captureInteractiveRegion(promptForPermission: promptForPermission)
    }

    private func optionalImage(id: UUID, options: RequestOptions, silent: Bool) async throws -> Data? {
        guard options.attachImage else { return nil }
        try checkRequest(id)
        guard options.mode != .claudeCode, ModelCapabilities.imageInput.contains(options.model) else { throw InputValidationError.unsupportedImageModel }
        requestProgress?.stage = .selectingImage
        if silent { quickCopyMessage = "첨부할 그림 영역을 직접 선택하세요 · Esc로 취소" }
        let image = try await captureImage(promptForPermission: !silent)
        try checkRequest(id)
        try InputAttachment.validate(image: image, model: options.model)
        capturedImage = NSImage(data: image)
        return image
    }

    func copyCode(_ id: Int) {
        guard !isWorking, status == .ready || status == .failed,
              let block = responseDocument.blocks.first(where: { $0.id == id && $0.isCode && $0.isComplete }),
              !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        copiedCodeID = clipboardWriter(block.text) ? id : nil
        copied = false
    }

    func restoreExplanation(_ text: String) {
        guard !isWorking, !text.isEmpty else { return }
        reset()
        explanation = text
        status = .ready
    }

    func reset() {
        cancelCurrentRequest()
        requestProgress = nil
        progressRequestID = nil
        status = .idle
        hasSelectionError = false
        hasInputError = false
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

    var currentModelName: String {
        let selected: String
        switch billingMode {
        case .chatGPT: selected = chatGPTModelName
        case .apiKey: selected = modelName
        case .claudeCode: selected = claudeModelName
        }
        return selected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var claudeCode: ClaudeCodeService {
        ClaudeCodeService(executablePath: claudeExecutablePath, model: claudeModelName)
    }

    private func inferenceProvider(options: RequestOptions, id: UUID, image: Data? = nil) async throws -> any InferenceProvider {
        try checkRequest(id)
        if options.mode == .claudeCode {
            let provider = ClaudeCodeService(executablePath: options.claudeExecutablePath, model: options.model,
                                             additionalInstructions: options.additionalInstructions)
            try await provider.checkInstalled()
            try checkRequest(id)
            return provider
        }
        let credential = try await inferenceCredential(mode: options.mode, model: options.model)
        try checkRequest(id)
        return OpenAIProvider(service: openAIService, credential: credential, model: options.model,
                              reasoningEffort: options.effort, onProgress: progressHandler(id: id),
                              imageData: image, additionalInstructions: options.additionalInstructions)
    }

    private func inferenceCredential(mode: BillingMode, model: String) async throws -> InferenceCredential {
        try Task.checkCancellation()
        if let credentialProvider { return try await credentialProvider(mode, model) }
        if mode == .apiKey {
            let key = try KeychainService.loadAPIKey()
            guard !key.isEmpty else { throw ChatGPTAuthError.oauth("API 키가 저장되지 않았습니다") }
            return .init(token: key, mode: .apiKey)
        }
        let token = try await chatGPTAuth.accessToken()
        try Task.checkCancellation()
        syncChatGPTProfiles()
        if chatGPTModels.isEmpty { try await loadChatGPTModels(token: token) }
        try Task.checkCancellation()
        guard chatGPTModels.contains(where: { $0.slug == model }) else {
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
        let models = try await openAIService.listChatGPTModels(accessToken: token)
        try Task.checkCancellation()
        chatGPTModels = models
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
            claudeStatus = try await claudeCode.status()
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
        let provider = claudeCode
        let task = Task { try await provider.login() }
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
