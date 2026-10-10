import CoreGraphics
import Foundation

enum ScreenCaptureError: LocalizedError, Equatable {
    case permissionDenied
    case cancelled
    case launchFailed(String)
    case emptyCapture

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "화면 기록 권한이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 StudyLens를 허용해 주세요."
        case .cancelled:
            return "캡처가 취소되었습니다."
        case .launchFailed(let detail):
            return "화면 캡처를 시작하지 못했습니다: \(detail)"
        case .emptyCapture:
            return "선택한 영역에서 이미지를 만들지 못했습니다. 다시 시도해 주세요."
        }
    }
}

struct ScreenCaptureService {
    func captureInteractiveRegion(promptForPermission: Bool = true) async throws -> Data {
        try Task.checkCancellation()
        if !CGPreflightScreenCaptureAccess(), !(promptForPermission && CGRequestScreenCaptureAccess()) {
            throw ScreenCaptureError.permissionDenied
        }

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyLens-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: target) }

        let capture = CancellableCaptureProcess(target: target)
        let exitCode = try await withTaskCancellationHandler {
            try await capture.run()
        } onCancel: {
            capture.cancel()
        }

        try Task.checkCancellation()
        guard exitCode == 0 else { throw ScreenCaptureError.cancelled }
        guard let data = try? Data(contentsOf: target), !data.isEmpty else {
            throw ScreenCaptureError.emptyCapture
        }
        return data
    }
}

/// Serialize cancellation with launch so cancellation before launch cannot orphan the picker.
private final class CancellableCaptureProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false

    init(target: URL) {
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-t", "png", target.path]
    }

    func run() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch { continuation.resume(throwing: ScreenCaptureError.launchFailed(error.localizedDescription)) }
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}
