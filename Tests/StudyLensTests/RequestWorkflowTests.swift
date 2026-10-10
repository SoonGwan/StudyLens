import AppKit
import XCTest
@testable import StudyLens

final class RequestWorkflowTests: XCTestCase {
    @MainActor
    func testCancelledLateGenerationCannotChangeNextResultOrClipboard() async throws {
        let model = AppModel(startServices: false)
        let pasteboard = NSPasteboard(name: .init("StudyLens.Cancel.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(ResponseClipboard.copy("previous", to: pasteboard))
        let started = expectation(description: "old generation started")
        var continuation: CheckedContinuation<String, Never>?
        let old = Task {
            await model.copySelectedCode(using: QuickCodeCopy(readSelection: { "old problem" }, generate: { _ in
                await withCheckedContinuation { pending in continuation = pending; started.fulfill() }
            }, write: { _ in XCTFail("Cancelled result wrote to clipboard"); return false }))
        }
        await fulfillment(of: [started], timeout: 2)
        model.cancelCurrentRequest()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.requestProgress?.stage, .cancelled)
        XCTAssertEqual(pasteboard.string(forType: .string), "previous")
        let nextResponse = "```python\nprint('next')\n```"
        await model.copySelectedCode(using: QuickCodeCopy(readSelection: { "next problem" }, generate: { _ in nextResponse }, write: { ResponseClipboard.copy($0, to: pasteboard) }))
        XCTAssertEqual(model.status, .ready)
        continuation?.resume(returning: "```java\nclass Old {}\n```")
        await old.value
        XCTAssertEqual(model.explanation, nextResponse)
        XCTAssertEqual(model.selectedText, "next problem")
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.requestProgress?.stage, .completed)
        XCTAssertEqual(pasteboard.string(forType: .string), "print('next')\n")
    }

    @MainActor
    func testCancelledSelectionDoesNotStartGenerationOrOpenWindow() async {
        let model = AppModel(startServices: false)
        let started = expectation(description: "selection started")
        var continuation: CheckedContinuation<String, Never>?
        var opens = 0
        let observer = NotificationCenter.default.addObserver(forName: .studyLensOpenResult, object: nil, queue: .main) { _ in opens += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let work = Task {
            await model.copySelectedCode(using: QuickCodeCopy(readSelection: {
                await withCheckedContinuation { continuation = $0; started.fulfill() }
            }, generate: { _ in XCTFail("Cancelled selection generated"); return "" }))
        }
        await fulfillment(of: [started], timeout: 2)
        model.cancelCurrentRequest()
        continuation?.resume(returning: "late selection")
        await work.value
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.selectedText, "")
        XCTAssertEqual(opens, 0)
    }

    @MainActor
    func testTimeoutNetworkAndCancellationHaveDifferentStatesWithoutRetry() async {
        let model = AppModel(startServices: false)
        for code in [URLError.Code.timedOut, .notConnectedToInternet, .cancelled] {
            var generations = 0
            await model.copySelectedCode(using: QuickCodeCopy(readSelection: { "problem" }, generate: { _ in
                generations += 1
                throw URLError(code)
            }, write: { _ in XCTFail("Failure wrote clipboard"); return false }))
            XCTAssertEqual(generations, 1)
            if code == .cancelled {
                XCTAssertEqual(model.status, .idle)
                XCTAssertNil(model.errorMessage)
                XCTAssertEqual(model.requestProgress?.stage, .cancelled)
            } else {
                XCTAssertEqual(model.status, .failed)
                XCTAssertEqual(model.requestProgress?.stage, .failed)
                if code == .timedOut { XCTAssertTrue(model.errorMessage?.contains("시간이 초과") == true) }
                else { XCTAssertEqual(model.errorMessage, URLError(code).localizedDescription) }
            }
        }
    }

    @MainActor
    func testModelAndEffortSnapshotSurvivesSettingsChangeDuringSelection() async throws {
        let suite = "StudyLens.Snapshot.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(startServices: false, reasoningSettings: .init(defaults: defaults))
        model.billingMode = .apiKey
        model.modelName = "gpt-6.1-sol"
        model.reasoningPreference = .medium
        let initial = expectation(description: "reading")
        var continuation: CheckedContinuation<String, Never>?
        let work = Task {
            await model.copySelectedCode(using: QuickCodeCopy(readSelection: {
                await withCheckedContinuation { continuation = $0; initial.fulfill() }
            }, generate: { _ in "```java\nclass Solution {}\n```" }, write: { _ in true }))
        }
        await fulfillment(of: [initial], timeout: 2)
        model.modelName = "gpt-4.1-mini"
        model.billingMode = .chatGPT
        continuation?.resume(returning: "problem")
        await work.value
        XCTAssertEqual(model.requestProgress?.model, "gpt-6.1-sol")
        XCTAssertEqual(model.requestProgress?.effort, "medium")
        XCTAssertEqual(model.requestProgress?.billingMode, .apiKey)
    }

    func testTimingSeparatesSelectionConnectionEventOutputAndCompletion() {
        var progress = RequestProgress(stage: .readingSelection, model: "synthetic", billingMode: .apiKey, effort: "low", now: 10)
        progress.finishSelection(now: 12)
        progress.prepareConnection(now: 15)
        progress.waitForResponse(now: 18)
        progress.record(.firstEvent, now: 20)
        progress.record(.firstText, now: 24)
        progress.record(.completed, now: 30)
        progress.finish(.completed, now: 31)
        XCTAssertEqual(progress.selectionDuration, 2)
        XCTAssertEqual(progress.connectionDuration, 3)
        XCTAssertEqual(progress.firstEvent, 10)
        XCTAssertEqual(progress.firstText, 14)
        XCTAssertEqual(progress.responseCompleted, 20)
        XCTAssertEqual(progress.elapsed(now: 100), 21)
        progress.record(.firstText, now: 40)
        XCTAssertEqual(progress.stage, .completed)
        XCTAssertEqual(progress.firstText, 14)
    }
}
