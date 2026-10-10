import CoreFoundation
import XCTest
@testable import SelectionCore

final class SelectedTextTests: XCTestCase {
    func testFocusedSelectionIsTrimmed() throws {
        let client = FakeSelectionClient(focus: 2, selections: [2: "  선택한 내용\n"])
        XCTAssertEqual(try SelectionResolver(client: client).resolve(in: 0), "선택한 내용")
    }

    func testMissingFocusFallsBackToWindowDocument() throws {
        let client = FakeSelectionClient(window: 1, childNodes: [1: [2], 2: [3]], selections: [3: "브라우저 문서 선택"])
        XCTAssertEqual(try SelectionResolver(client: client).resolve(in: 0), "브라우저 문서 선택")
    }

    func testParentWebAreaProvidesSelection() throws {
        let client = FakeSelectionClient(focus: 3, parents: [3: 2, 2: 1], selections: [2: "문서 선택"])
        XCTAssertEqual(try SelectionResolver(client: client).resolve(in: 0), "문서 선택")
    }

    func testAncestorWalkDoesNotPreventDescendingIntoWindow() throws {
        let client = FakeSelectionClient(focus: 2, window: 1, parents: [2: 1],
                                         childNodes: [1: [2], 2: [3]], selections: [3: "선택"])
        XCTAssertEqual(try SelectionResolver(client: client).resolve(in: 0), "선택")
    }

    func testSecureAncestorBlocksChildTextBeforeRead() {
        let client = FakeSelectionClient(focus: 3, window: 1, parents: [3: 2],
                                         selections: [3: "비밀"], secure: [2])
        XCTAssertThrowsError(try SelectionResolver(client: client).resolve(in: 0)) {
            XCTAssertEqual($0 as? SelectedTextError, .secureInput)
        }
        XCTAssertEqual(client.textReads, 0)
    }

    func testWindowScanSkipsHiddenAndSecureSubtrees() throws {
        let client = FakeSelectionClient(window: 1, childNodes: [1: [2, 3, 4], 2: [5], 3: [6]],
                                         selections: [5: "숨김", 6: "비밀", 4: "일반 선택"], secure: [3], hidden: [2])
        XCTAssertEqual(try SelectionResolver(client: client).resolve(in: 0), "일반 선택")
    }

    func testCyclesTerminateWithoutSelection() {
        let client = FakeSelectionClient(focus: 2, window: 1, parents: [2: 2], childNodes: [1: [2], 2: [1]])
        XCTAssertThrowsError(try SelectionResolver(client: client).resolve(in: 0)) {
            XCTAssertEqual($0 as? SelectedTextError, .noSelection)
        }
        XCTAssertLessThanOrEqual(client.textReads, 3)
    }

    func testNodeBudgetStopsTraversal() {
        let client = FakeSelectionClient(window: 1, childNodes: [1: Array(2...100)], selections: [100: "선택"])
        XCTAssertThrowsError(try SelectionResolver(client: client, maxNodes: 5).resolve(in: 0)) {
            XCTAssertEqual($0 as? SelectedTextError, .noSelection)
        }
        XCTAssertEqual(client.textReads, 5)
    }

    func testEmptySelectionIsNotAnExplanationInput() {
        let client = FakeSelectionClient(focus: 2, window: 1, selections: [2: " \n\t"])
        XCTAssertThrowsError(try SelectionResolver(client: client).resolve(in: 0)) {
            XCTAssertEqual($0 as? SelectedTextError, .noSelection)
        }
    }

    func testLongSelectionIsRejectedInsteadOfSilentlyTruncated() {
        let client = FakeSelectionClient(focus: 2, selections: [2: String(repeating: "가", count: 30_001)])
        XCTAssertThrowsError(try SelectionResolver(client: client).resolve(in: 0)) {
            XCTAssertEqual($0 as? SelectedTextError, .selectionTooLong)
        }
    }

    func testExplicitSelectionRangeUsesUTF16Offsets() {
        XCTAssertEqual(NativeSelectionAccessibilityClient.substring("A😀한글", range: CFRange(location: 1, length: 2)), "😀")
        XCTAssertEqual(NativeSelectionAccessibilityClient.substring("A😀한글", range: CFRange(location: 3, length: 2)), "한글")
    }

    func testInvalidAndEmptyRangesCannotReadWholeValue() {
        for range in [CFRange(location: -1, length: 2), CFRange(location: 0, length: 0),
                      CFRange(location: 2, length: Int.max), CFRange(location: 100, length: 1)] {
            XCTAssertNil(NativeSelectionAccessibilityClient.substring("학습", range: range))
        }
    }
}

private final class FakeSelectionClient: SelectionAccessibilityClient {
    var focus: Int?
    var window: Int?
    var parents: [Int: Int]
    var childNodes: [Int: [Int]]
    var selections: [Int: String]
    var secure: Set<Int>
    var hidden: Set<Int>
    var textReads = 0

    init(focus: Int? = nil, window: Int? = nil, parents: [Int: Int] = [:], childNodes: [Int: [Int]] = [:],
         selections: [Int: String] = [:], secure: Set<Int> = [], hidden: Set<Int> = []) {
        self.focus = focus; self.window = window; self.parents = parents; self.childNodes = childNodes
        self.selections = selections; self.secure = secure; self.hidden = hidden
    }
    func focusedElement(in application: Int) -> Int? { focus }
    func focusedWindow(in application: Int) -> Int? { window }
    func parent(of element: Int) -> Int? { parents[element] }
    func children(of element: Int) -> [Int] { childNodes[element] ?? [] }
    func selectedText(of element: Int) throws -> String? { textReads += 1; return selections[element] }
    func isSecure(_ element: Int) -> Bool { secure.contains(element) }
    func isHidden(_ element: Int) -> Bool { hidden.contains(element) }
}

final class SelectedTextErrorCodeTests: XCTestCase {
    func testErrorCodesMatchHelperProtocol() {
        XCTAssertEqual(SelectedTextError.permissionDenied.code, "permissionDenied")
        XCTAssertEqual(SelectedTextError.noFocusedApplication.code, "noFocusedApplication")
        XCTAssertEqual(SelectedTextError.noSelection.code, "noSelection")
        XCTAssertEqual(SelectedTextError.secureInput.code, "secureInput")
        XCTAssertEqual(SelectedTextError.selectionTooLong.code, "selectionTooLong")
    }
}
