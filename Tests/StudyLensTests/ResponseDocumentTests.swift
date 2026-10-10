import AppKit
import XCTest
@testable import StudyLens

final class ResponseDocumentTests: XCTestCase {
    func testCodeCopyExcludesExplanationAndFencesButPreservesSource() {
        let code = "class Solution {\n\t// 다음 줄을 주석에 합치면 안 됩니다.\n    String s = \"\\n```literal\";\n\n    int answer = 1;\n}\n"
        let document = ResponseDocument("설명입니다.\n\n```java\n" + code + "```\n\n추가 설명")
        XCTAssertEqual(document.blocks.count, 3)
        XCTAssertEqual(document.blocks[1].language, "java")
        XCTAssertEqual(document.blocks[1].text, code)
    }

    func testMultipleCodeBlocksKeepIndependentLanguagesAndBodies() {
        let document = ResponseDocument("```java\nint x = 1;\n```\n설명\n~~~python\nprint(2)\n~~~")
        XCTAssertEqual(document.blocks.filter(\.isCode).map(\.text), ["int x = 1;\n", "print(2)\n"])
        XCTAssertEqual(document.blocks.map(\.id), [0, 1, 2])
        XCTAssertEqual(document.blocks[2].language, "python")
    }

    func testLongFenceContainsShortFencesAndBackticks() {
        let document = ResponseDocument("````text\n```java\nint x;\n```\n````")
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].text, "```java\nint x;\n```\n")
    }

    func testUnclosedCodeBlockDoesNotLoseLastLine() {
        let document = ResponseDocument("```java\nclass Solution {\n    int x;")
        XCTAssertEqual(document.blocks[0].text, "class Solution {\n    int x;")
    }

    func testCRLFAndTabsSurviveCodeExtraction() {
        let code = "class Solution {\r\n\tint x;\r\n}\r\n"
        let document = ResponseDocument("```java\r\n" + code + "```\r\n")
        XCTAssertEqual(document.blocks[0].text, code)
    }

    func testExplanationRenderingPreservesParagraphBreaks() {
        let source = "첫 문단\n\n둘째 문단\n    들여쓰기"
        XCTAssertEqual(String(ResponseBodyView.prose(source).characters), source)
    }

    @MainActor
    func testPlainTextPasteboardRoundTripKeepsNewlinesAndIndentation() {
        let pasteboard = NSPasteboard(name: .init("StudyLens.CopyTest.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let code = "class Solution {\n    // 주석\n\tint x = 1;\n}\n"
        let document = ResponseDocument("설명\n```java\n" + code + "```\n설명 끝")
        XCTAssertTrue(ResponseClipboard.copy(document.blocks[1].text, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), code)
        XCTAssertTrue(pasteboard.types?.contains(.string) == true)
        XCTAssertFalse(pasteboard.types?.contains(.rtf) == true)
        XCTAssertFalse(pasteboard.types?.contains(.html) == true)
    }
}
