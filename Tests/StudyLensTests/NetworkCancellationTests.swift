import Foundation
import XCTest
@testable import StudyLens

final class NetworkCancellationTests: XCTestCase {
    func testCancelStopsPendingStreamWithoutReturningPartialCodeOrRetrying() async throws {
        let started = expectation(description: "stream started")
        let stopped = expectation(description: "URL loading stopped")
        let state = CancellationProtocolState(started: started, stopped: stopped)
        PendingStreamProtocol.state = state
        defer { PendingStreamProtocol.state = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingStreamProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = OpenAIService(session: session)
        let request = Task {
            try await service.generateCode(selectedText: "synthetic problem", language: "Java",
                credential: .init(token: "synthetic", mode: .chatGPT), model: "gpt-6.1-sol")
        }
        await fulfillment(of: [started], timeout: 2)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled stream returned code") }
        catch is CancellationError { }
        catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(state.requests, 1)
    }
}

private final class CancellationProtocolState: @unchecked Sendable {
    let started: XCTestExpectation
    let stopped: XCTestExpectation
    private let lock = NSLock()
    private var count = 0
    init(started: XCTestExpectation, stopped: XCTestExpectation) { self.started = started; self.stopped = stopped }
    func begin() { lock.lock(); count += 1; lock.unlock(); started.fulfill() }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class PendingStreamProtocol: URLProtocol {
    static var state: CancellationProtocolState?
    private var requestState: CancellationProtocolState?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        requestState = Self.state
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let partial = "data: {\"type\":\"response.created\"}\n\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"```java\\nclass Incomplete {\"}\n\n"
        client?.urlProtocol(self, didLoad: Data(partial.utf8))
        requestState?.begin()
        // Deliberately withhold response.completed; cancellation must stop this network task.
    }
    override func stopLoading() { requestState?.stopped.fulfill() }
}
