import Foundation
import XCTest
@testable import StudyLens

final class ClaudeCodeServiceTests: XCTestCase {
    func testArgumentsIsolateUserSetupAndDisableTools() {
        let arguments = ClaudeCodeService.arguments(systemPrompt: "지침", model: " sonnet ")
        XCTAssertEqual(arguments.prefix(1), ["-p"])
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        XCTAssertTrue(arguments.contains("--disable-slash-commands"))
        XCTAssertTrue(arguments.contains("--no-session-persistence"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--tools")! + 1], "")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--setting-sources")! + 1], "")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--system-prompt")! + 1], "지침")
        XCTAssertEqual(arguments.suffix(2), ["--model", "sonnet"])
        XCTAssertFalse(ClaudeCodeService.arguments(systemPrompt: "지침", model: "").contains("--model"))
    }

    func testInputLineCarriesImageAsBase64Block() throws {
        let line = try ClaudeCodeService.inputLine(content: [ClaudeCodeService.imageBlock(Data([1, 2, 3])), ClaudeCodeService.textBlock("설명")])
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "user")
        let content = try XCTUnwrap((object["message"] as? [String: Any])?["content"] as? [[String: Any]])
        let source = try XCTUnwrap(content[0]["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "AQID")
        XCTAssertEqual(content[1]["text"] as? String, "설명")
    }

    func testParseResultReturnsFinalResultText() throws {
        let stdout = """
        {"type":"system","subtype":"init"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"부분"}]}}
        {"type":"result","subtype":"success","is_error":false,"result":"  최종 설명\\n"}
        """
        XCTAssertEqual(try ClaudeCodeService.parseResult(stdout: Data(stdout.utf8), stderr: Data()), "최종 설명")
    }

    func testParseResultSurfacesErrors() {
        let modelError = #"{"type":"result","is_error":true,"api_error_status":404,"result":"There's an issue with the selected model"}"#
        XCTAssertThrowsError(try ClaudeCodeService.parseResult(stdout: Data(modelError.utf8), stderr: Data())) { error in
            XCTAssertEqual(error.localizedDescription, "Claude 오류: There's an issue with the selected model")
        }
        let authError = #"{"type":"result","is_error":true,"api_error_status":401,"result":"Invalid API key"}"#
        XCTAssertThrowsError(try ClaudeCodeService.parseResult(stdout: Data(authError.utf8), stderr: Data())) { error in
            guard case ClaudeCodeError.notLoggedIn = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ClaudeCodeService.parseResult(stdout: Data(), stderr: Data("Not logged in · Please run /login".utf8))) { error in
            guard case ClaudeCodeError.notLoggedIn = error else { return XCTFail("\(error)") }
        }
        let empty = #"{"type":"result","is_error":false,"result":""}"#
        XCTAssertThrowsError(try ClaudeCodeService.parseResult(stdout: Data(empty.utf8), stderr: Data())) { error in
            guard case ClaudeCodeError.emptyOutput = error else { return XCTFail("\(error)") }
        }
    }

    func testRunsConfiguredExecutableWithStdinMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("claude")
        // Echo the received user text back so the test proves stdin reached the CLI.
        try """
        #!/bin/sh
        input=$(cat)
        case "$input" in
          *'"text":"선택한 문제"'*) echo '{"type":"result","is_error":false,"result":"받음"}' ;;
          *) echo '{"type":"result","is_error":true,"result":"입력 없음"}' ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let result = try await ClaudeCodeService(executablePath: script.path).explain(selectedText: "선택한 문제")
        XCTAssertEqual(result, "받음")
    }

    func testNVMCandidatesPreferNewestNodeVersion() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for version in ["v9.0.0", "v22.23.2", "v18.1.0"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".nvm/versions/node/\(version)/bin"), withIntermediateDirectories: true)
        }
        let candidates = ClaudeCodeService.versionManagerCandidates(home: home.path)
        XCTAssertEqual(candidates.prefix(3).map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent },
                       ["v22.23.2", "v18.1.0", "v9.0.0"])
    }

    func testMissingConfiguredExecutableIsReported() {
        XCTAssertThrowsError(try ClaudeCodeService.locateExecutable(override: "/nonexistent/claude")) { error in
            guard case ClaudeCodeError.notInstalled = error else { return XCTFail("\(error)") }
        }
    }

    func testStatusDecodesClaudeCodeJSON() throws {
        let json = #"{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.c","subscriptionType":"max"}"#
        let status = try JSONDecoder().decode(ClaudeCodeStatus.self, from: Data(json.utf8))
        XCTAssertTrue(status.loggedIn)
        XCTAssertEqual(status.label, "a@b.c · Max")
    }
}
