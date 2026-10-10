import AppKit
import XCTest
@testable import StudyLens

final class StudyLensTests: XCTestCase {
    func testDefaultShortcutHasRequiredModifier() {
        let shortcut = HotKeyConfiguration.captureDefault
        XCTAssertNotEqual(shortcut.modifiers, 0)
        XCTAssertEqual(shortcut.displayName, "⇧⌘9")
        XCTAssertEqual(HotKeyConfiguration.textDefault.displayName, "⇧⌘0")
        XCTAssertNotEqual(shortcut, HotKeyConfiguration.textDefault)
    }

    func testTutorInstructionsBlockLiveAssessmentAssistance() {
        XCTAssertTrue(OpenAIService.instructions.contains("진행 중인 시험"))
        XCTAssertTrue(OpenAIService.instructions.contains("자동 입력"))
        XCTAssertTrue(OpenAIService.instructions.contains("감독 회피"))
    }

    func testMenuOnlyOpensForOptionClick() {
        XCTAssertEqual(StatusItemInteraction.iconTitle, "●")
        XCTAssertFalse(StatusItemInteraction.shouldToggleMenu(for: []))
        XCTAssertFalse(StatusItemInteraction.shouldToggleMenu(for: .command))
        XCTAssertTrue(StatusItemInteraction.shouldToggleMenu(for: .option))
        XCTAssertTrue(StatusItemInteraction.shouldToggleMenu(for: [.option, .shift]))
    }
}
