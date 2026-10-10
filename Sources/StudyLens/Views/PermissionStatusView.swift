import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

struct PermissionStatusView: View {
    @State private var accessibilityAvailable = AXIsProcessTrusted()
    @State private var screenCaptureAvailable = CGPreflightScreenCaptureAccess()

    var body: some View {
        Section("현재 앱의 권한") {
            Label(accessibilityAvailable ? "접근성: 사용 가능" : "접근성: 현재 앱 접근 불가",
                  systemImage: accessibilityAvailable ? "checkmark.circle" : "exclamationmark.triangle")
            Label(screenCaptureAvailable ? "화면 기록: 사용 가능" : "화면 기록: 현재 앱 접근 불가",
                  systemImage: screenCaptureAvailable ? "checkmark.circle" : "exclamationmark.triangle")
            HStack {
                Button("권한 상태 새로고침", action: refresh)
                Button("손쉬운 사용 설정") { openSettings("Privacy_Accessibility") }
                Button("화면 기록 설정") { openSettings("Privacy_ScreenCapture") }
            }
            Text("접근성은 선택 텍스트 읽기, 화면 기록은 직접 선택한 영역 캡처에 필요합니다. 이 상태는 macOS가 현재 실행 중인 앱에 허용한 접근을 확인하며, 특정 앱의 선택 텍스트 호환성까지 보장하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("업데이트 후 시스템 설정의 스위치가 켜져 있어도 이전 임시 서명의 허용일 수 있습니다. StudyLens를 종료하고 손쉬운 사용에서 기존 항목을 제거한 뒤 새 앱을 같은 설치 경로에 등록·허용하고 재실행하세요. 화면 기록은 별도로 확인하세요. 권한 문제는 로그인·사용량 오류와 별개입니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        accessibilityAvailable = AXIsProcessTrusted()
        screenCaptureAvailable = CGPreflightScreenCaptureAccess()
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
