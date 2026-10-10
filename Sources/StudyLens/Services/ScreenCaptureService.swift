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
    func captureInteractiveRegion() async throws -> Data {
        if !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
            throw ScreenCaptureError.permissionDenied
        }

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyLens-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: target) }

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", "-t", "png", target.path]
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ScreenCaptureError.launchFailed(error.localizedDescription))
            }
        }

        guard exitCode == 0 else { throw ScreenCaptureError.cancelled }
        guard let data = try? Data(contentsOf: target), !data.isEmpty else {
            throw ScreenCaptureError.emptyCapture
        }
        return data
    }
}
