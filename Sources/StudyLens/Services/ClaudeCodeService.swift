import Foundation

enum ClaudeCodeError: LocalizedError {
    case notInstalled
    case notLoggedIn
    case failed(String)
    case emptyOutput
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Claude Code(claude)를 찾지 못했습니다. Claude Code를 설치하거나 설정에서 실행 파일 경로를 입력해 주세요."
        case .notLoggedIn:
            return "Claude Code에 로그인되어 있지 않습니다. 설정에서 Claude 로그인을 눌러 주세요."
        case .failed(let message):
            return "Claude 오류: \(message)"
        case .emptyOutput:
            return "Claude가 설명을 반환하지 않았습니다. 다시 요청해 주세요."
        case .timedOut:
            return "Claude 응답 시간이 초과되었습니다. 다시 요청해 주세요."
        }
    }
}

struct ClaudeCodeStatus: Decodable, Equatable {
    let loggedIn: Bool
    let authMethod: String?
    let email: String?
    let subscriptionType: String?

    var label: String {
        let plan = subscriptionType.map { " · \($0.capitalized)" } ?? ""
        return "\(email ?? "Claude 계정")\(plan)"
    }
}

/// Runs the user's own Claude Code CLI in headless print mode, so requests use the
/// subscription Claude Code is signed in with. StudyLens never reads Claude Code's tokens.
struct ClaudeCodeService {
    static let models: [(id: String, title: String)] = [
        ("", "Claude Code 기본값"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")
    ]

    func explain(imageData: Data, executablePath: String, model: String) async throws -> String {
        try await perform(
            content: [
                Self.imageBlock(imageData),
                Self.textBlock("화면 이미지의 내용과 사용자의 요청을 읽고 요청에 맞게 답해 주세요. 별도의 요청이 없으면 문제의 답과 풀이를 한국어로 제공해 주세요.")
            ],
            systemPrompt: OpenAIService.instructions,
            executablePath: executablePath,
            model: model
        )
    }

    func explain(selectedText: String, executablePath: String, model: String) async throws -> String {
        try await perform(content: [Self.textBlock(selectedText)], systemPrompt: OpenAIService.instructions, executablePath: executablePath, model: model)
    }

    func generateCode(selectedText: String, language: String, executablePath: String, model: String) async throws -> String {
        try await perform(
            content: [Self.textBlock(selectedText)],
            systemPrompt: OpenAIService.codeInstructions(language: language),
            executablePath: executablePath,
            model: model
        )
    }

    func status(executablePath: String) async throws -> ClaudeCodeStatus {
        let executable = try Self.locateExecutable(override: executablePath)
        let output = try await ProcessRunner.run(executable, arguments: ["auth", "status", "--json"], timeout: 30)
        guard let status = try? JSONDecoder().decode(ClaudeCodeStatus.self, from: output.stdout) else {
            throw ClaudeCodeError.failed(Self.trimmed(output.stderr) ?? "로그인 상태를 읽지 못했습니다.")
        }
        return status
    }

    /// Claude Code opens the browser and handles the sign-in itself.
    func login(executablePath: String) async throws {
        let executable = try Self.locateExecutable(override: executablePath)
        let output = try await ProcessRunner.run(executable, arguments: ["auth", "login", "--claudeai"], timeout: 600)
        guard output.status == 0 else {
            throw ClaudeCodeError.failed(Self.trimmed(output.stderr) ?? Self.trimmed(output.stdout) ?? "로그인하지 못했습니다.")
        }
    }

    private func perform(content: [[String: Any]], systemPrompt: String, executablePath: String, model: String) async throws -> String {
        let executable = try Self.locateExecutable(override: executablePath)
        let output = try await ProcessRunner.run(
            executable,
            arguments: Self.arguments(systemPrompt: systemPrompt, model: model),
            input: try Self.inputLine(content: content),
            timeout: 300
        )
        return try Self.parseResult(stdout: output.stdout, stderr: output.stderr)
    }

    /// Isolated from the user's settings, MCP servers, skills and tools: a single text-only turn.
    static func arguments(systemPrompt: String, model: String) -> [String] {
        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "",
            "--no-session-persistence", "--system-prompt", systemPrompt
        ]
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { arguments += ["--model", model] }
        return arguments
    }

    static func textBlock(_ text: String) -> [String: Any] { ["type": "text", "text": text] }

    static func imageBlock(_ png: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]]
    }

    static func inputLine(content: [[String: Any]]) throws -> Data {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        return try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)
    }

    static func parseResult(stdout: Data, stderr: Data) throws -> String {
        let lines = String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
        let result = lines.reversed().lazy
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .first { $0["type"] as? String == "result" }
        guard let result else {
            let message = trimmed(stderr) ?? "응답을 읽지 못했습니다."
            if message.localizedCaseInsensitiveContains("login") || message.localizedCaseInsensitiveContains("log in") {
                throw ClaudeCodeError.notLoggedIn
            }
            throw ClaudeCodeError.failed(message)
        }
        let text = (result["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if result["is_error"] as? Bool == true {
            if result["api_error_status"] as? Int == 401 { throw ClaudeCodeError.notLoggedIn }
            throw ClaudeCodeError.failed(text.isEmpty ? (trimmed(stderr) ?? "요청이 실패했습니다.") : text)
        }
        guard !text.isEmpty else { throw ClaudeCodeError.emptyOutput }
        return text
    }

    /// Apps launched from Finder don't inherit the shell PATH, so check the usual install
    /// locations and then ask the user's login shell.
    static func locateExecutable(override: String) throws -> URL {
        let fileManager = FileManager.default
        let custom = (override.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        if !custom.isEmpty {
            guard fileManager.isExecutableFile(atPath: custom) else { throw ClaudeCodeError.notInstalled }
            return URL(fileURLWithPath: custom)
        }
        if let cached = cachedExecutable.value, fileManager.isExecutableFile(atPath: cached.path) { return cached }
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            + versionManagerCandidates(home: home)
        let found = candidates.first { fileManager.isExecutableFile(atPath: $0) } ?? shellLookup()
        guard let found else { throw ClaudeCodeError.notInstalled }
        let url = URL(fileURLWithPath: found)
        cachedExecutable.value = url
        return url
    }

    private static let cachedExecutable = LockedValue<URL?>(nil)

    /// Version managers such as nvm install global packages per Node version.
    static func versionManagerCandidates(home: String) -> [String] {
        let fileManager = FileManager.default
        let nvmRoot = "\(home)/.nvm/versions/node"
        let nvm = ((try? fileManager.contentsOfDirectory(atPath: nvmRoot)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(nvmRoot)/\($0)/bin/claude" }
        return nvm + ["\(home)/.volta/bin/claude", "\(home)/.bun/bin/claude", "\(home)/.npm-global/bin/claude"]
    }

    /// Non-interactive: an interactive shell without a terminal can block indefinitely.
    private static func shellLookup(timeout: TimeInterval = 5) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v claude"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = LockedValue(Data())
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.value = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        return String(decoding: output.value, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func trimmed(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(500))
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

enum ProcessRunner {
    struct Output { let status: Int32; let stdout: Data; let stderr: Data }

    /// Runs in a private temporary directory and terminates the process on task cancellation or timeout.
    static func run(_ executable: URL, arguments: [String], input: Data? = nil, timeout: TimeInterval) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        let directory = executable.deletingLastPathComponent().path
        environment["PATH"] = [directory, environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let timedOut = LockedValue(false)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try process.run() } catch {
                        continuation.resume(throwing: ClaudeCodeError.notInstalled)
                        return
                    }
                    let group = DispatchGroup()
                    var out = Data(), err = Data()
                    group.enter()
                    DispatchQueue.global().async { out = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                    group.enter()
                    DispatchQueue.global().async { err = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                    if let input {
                        DispatchQueue.global().async {
                            try? stdin.fileHandleForWriting.write(contentsOf: input)
                            try? stdin.fileHandleForWriting.close()
                        }
                    }
                    let timer = DispatchWorkItem {
                        guard process.isRunning else { return }
                        timedOut.value = true
                        process.terminate()
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                    process.waitUntilExit()
                    group.wait()
                    timer.cancel()
                    if timedOut.value { continuation.resume(throwing: ClaudeCodeError.timedOut); return }
                    if process.terminationReason == .uncaughtSignal { continuation.resume(throwing: CancellationError()); return }
                    continuation.resume(returning: Output(status: process.terminationStatus, stdout: out, stderr: err))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
