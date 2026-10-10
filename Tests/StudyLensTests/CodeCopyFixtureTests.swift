import AppKit
import XCTest
@testable import StudyLens

/// Synthetic regression cases only; no user response is harvested or stored.
private struct CodeCopyFixture {
    let name: String
    let response: String
    let expectedCode: String?
    let error: QuickCodeCopyError?

    static let all: [Self] = {
        var fixtures: [Self] = []
        let languages = [
            ("java", "class Solution {\n\t// example\n\n    int answer = 1;\n}\n"),
            ("python", "# example\ndef solve():\n\tprint(1)\n\nsolve()\n"),
            ("cpp", "#include <iostream>\n// example\nint main() {\n\tstd::cout << 1;\n}\n")
        ]
        for (language, code) in languages {
            for lineEnding in ["\n", "\r\n"] {
                let body = code.replacingOccurrences(of: "\n", with: lineEnding)
                let fence = "```" + language + lineEnding + body + "```"
                let name = language + (lineEnding == "\n" ? "-LF" : "-CRLF")
                fixtures.append(.init(name: name, response: fence, expectedCode: body, error: nil))
                fixtures.append(.init(name: name + "-prose", response: "설명" + lineEnding + fence + lineEnding + "설명 끝", expectedCode: body, error: nil))
                fixtures.append(.init(name: name + "-multiple", response: fence + lineEnding + fence, expectedCode: nil, error: .multipleCodeBlocks(2)))
                fixtures.append(.init(name: name + "-empty", response: "```" + language + lineEnding + "```", expectedCode: nil, error: .emptyCode))
                fixtures.append(.init(name: name + "-incomplete", response: "```" + language + lineEnding + body, expectedCode: nil, error: .incompleteCode))
                fixtures.append(.init(name: name + "-raw", response: body, expectedCode: language == "java" ? body : nil, error: language == "java" ? nil : .noCode))
            }
        }
        fixtures.append(.init(name: "no-code", response: "그림에서 누락된 선로 방향을 알려 주세요.", expectedCode: nil, error: .noCode))
        return fixtures
    }()
}

final class CodeCopyFixtureTests: XCTestCase {
    @MainActor
    func testSameSyntheticFixturesAcrossDisplayManualWholeAndQuickCopy() async throws {
        let pasteboard = NSPasteboard(name: .init("StudyLens.Fixtures.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let write: (String) -> Bool = { ResponseClipboard.copy($0, to: pasteboard) }
        let model = AppModel(startServices: false, clipboardWriter: write)
        for fixture in CodeCopyFixture.all {
            let normalized = QuickCodeCopy.normalizeCompleteJavaSource(fixture.response)
            let document = ResponseDocument(normalized)
            model.restoreExplanation(normalized)
            XCTAssertEqual(model.responseDocument.blocks, document.blocks, fixture.name)
            model.copyExplanation()
            XCTAssertEqual(pasteboard.string(forType: .string), normalized, fixture.name)
            for block in document.blocks where block.isCode && block.isComplete && !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.copyCode(block.id)
                XCTAssertEqual(pasteboard.string(forType: .string), block.text, fixture.name)
            }
            XCTAssertTrue(write("previous"))
            await model.copySelectedCode(using: QuickCodeCopy(readSelection: { "synthetic problem" }, generate: { _ in fixture.response }, write: write))
            if let code = fixture.expectedCode {
                XCTAssertEqual(model.status, .ready, fixture.name)
                XCTAssertEqual(pasteboard.string(forType: .string), code, fixture.name)
                XCTAssertEqual(document.blocks.filter(\.isCode).first?.text, code, fixture.name)
            } else {
                XCTAssertEqual(model.status, .failed, fixture.name)
                XCTAssertEqual(model.errorMessage, fixture.error?.localizedDescription, fixture.name)
                XCTAssertEqual(pasteboard.string(forType: .string), "previous", fixture.name)
            }
        }
    }
}
