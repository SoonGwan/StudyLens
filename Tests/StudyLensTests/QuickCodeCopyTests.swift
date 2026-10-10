import AppKit
import XCTest
@testable import StudyLens

final class QuickCodeCopyTests: XCTestCase {
    @MainActor
    func testCopiesOnlyCompleteCodeAndReadsSelectionFirst() async throws {
        let pasteboard = NSPasteboard(name: .init("StudyLens.QuickCopy.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let code = "class Solution {\n    // 줄바꿈 보존\n\tint x = 1;\n}\n"
        var order: [String] = []
        let workflow = QuickCodeCopy(readSelection: {
            order.append("read")
            return "문제 Java 코드로 만들어줘"
        }, generate: { text in
            order.append("generate")
            XCTAssertEqual(text, "문제 Java 코드로 만들어줘")
            return "설명\n```java\n" + code + "```\n설명 끝"
        }, write: { ResponseClipboard.copy($0, to: pasteboard) })
        let id = try await workflow.run()
        XCTAssertEqual(id, 1)
        XCTAssertEqual(order, ["read", "generate"])
        XCTAssertEqual(pasteboard.string(forType: .string), code)
    }

    @MainActor
    func testMissingMultipleUnclosedAndEmptyCodeDoNotReplaceClipboard() async {
        let pasteboard = NSPasteboard(name: .init("StudyLens.QuickCopy.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(ResponseClipboard.copy("기존 클립보드", to: pasteboard))
        for response in ["추가 정보가 필요합니다", "```java\nint x;", "```java\nint x;\n```\n```java\nint y;\n```", "```java\n\n```"] {
            let workflow = QuickCodeCopy(readSelection: { "문제" }, generate: { _ in response }, write: { ResponseClipboard.copy($0, to: pasteboard) })
            do { _ = try await workflow.run(); XCTFail("Invalid response accepted") }
            catch { XCTAssertTrue(error is QuickCodeCopyError) }
            XCTAssertEqual(pasteboard.string(forType: .string), "기존 클립보드")
        }
    }

    @MainActor
    func testGenerationFailureDoesNotWrite() async {
        var writes = 0
        let workflow = QuickCodeCopy(readSelection: { "문제" }, generate: { _ in throw OpenAIServiceError.interruptedStream }, write: { _ in writes += 1; return true })
        do { _ = try await workflow.run(); XCTFail("Must fail") } catch { }
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testStandaloneJavaWithoutMarkdownCanBeCopied() async throws {
        let code = "// 필요한 가정\nimport java.util.*;\nclass Solution {\n\tString s = \"}\\\"\";\n    /* { */ int x = 1;\n}\n"
        var copied = ""
        let workflow = QuickCodeCopy(readSelection: { "문제" }, generate: { _ in code }, write: { copied = $0; return true })
        _ = try await workflow.run()
        XCTAssertEqual(copied, code)
    }

    @MainActor
    func testRawProseAndUnbalancedJavaRemainUncopied() async {
        for response in ["아래 코드를 사용하세요.\nclass Solution {}", "class Solution {\nvoid solve() {\n}", "추가 그림이 필요합니다", "class Solution { String s = \"unfinished; }"] {
            var writes = 0
            let workflow = QuickCodeCopy(readSelection: { "문제" }, generate: { _ in response }, write: { _ in writes += 1; return true })
            do { _ = try await workflow.run(); XCTFail("Invalid raw code accepted") }
            catch { XCTAssertEqual(error as? QuickCodeCopyError, .noCode) }
            XCTAssertEqual(writes, 0)
        }
    }

    @MainActor
    func testFailurePreservesActualResponseForManualInspection() async {
        let model = AppModel(startServices: false)
        let response = "4~6번 선로의 방향이 필요합니다."
        await model.copySelectedCode(using: QuickCodeCopy(readSelection: { "문제" }, generate: { _ in response }, write: { _ in XCTFail("No code to write"); return true }))
        XCTAssertEqual(model.status, .failed)
        XCTAssertEqual(model.explanation, response)
        XCTAssertEqual(model.errorMessage, QuickCodeCopyError.noCode.localizedDescription)
    }

    @MainActor
    func testStatusDotsAreNonTemplateAndContainActualStatusColor() throws {
        for (status, channel) in [(AppModel.Status.analyzing, "orange"), (.ready, "green"), (.failed, "red")] {
            let image = StatusDot.image(for: status)
            XCTAssertFalse(image.isTemplate)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            switch channel {
            case "green": XCTAssertGreaterThan(color.greenComponent, color.redComponent)
            case "red": XCTAssertGreaterThan(color.redComponent, color.greenComponent)
            default: XCTAssertGreaterThan(color.redComponent, color.blueComponent)
            }
        }
        XCTAssertTrue(StatusDot.image(for: .idle).isTemplate)
    }

    @MainActor
    func testSilentModelNeverOpensResultOnSuccessOrFailure() async {
        let model = AppModel(startServices: false)
        var opened = 0
        let observer = NotificationCenter.default.addObserver(forName: .studyLensOpenResult, object: nil, queue: .main) { _ in opened += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        await model.copySelectedCode(using: QuickCodeCopy(readSelection: { "문제" }, generate: { _ in "```java\nclass Solution {}\n```" }, write: { _ in true }))
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.copiedCodeID, 0)
        XCTAssertEqual(model.quickCopyMessage, "코드 복사 완료 · ⌘V로 붙여넣기")
        await model.copySelectedCode(using: QuickCodeCopy(readSelection: { throw SelectedTextError.permissionDenied }, generate: { _ in XCTFail("Should not generate"); return "" }, write: { _ in XCTFail("Should not write"); return false }))
        XCTAssertEqual(model.status, .failed)
        XCTAssertTrue(model.hasSelectionError)
        XCTAssertEqual(opened, 0)
    }

    func testDedicatedPromptRespectsExplicitLanguageAndRequestsOneCodeBlock() {
        let instructions = OpenAIService.codeInstructions(language: "Java")
        XCTAssertTrue(instructions.contains("기본 언어 Java"))
        XCTAssertTrue(instructions.contains("정확히 하나의 Markdown 코드 블록"))
        XCTAssertTrue(instructions.contains("사용자가 본문에서 코드 언어를 지정하면 그 언어를 따르고"))
        XCTAssertNotEqual(HotKeyConfiguration.codeDefault, .captureDefault)
        XCTAssertNotEqual(HotKeyConfiguration.codeDefault, .textDefault)
    }
}
