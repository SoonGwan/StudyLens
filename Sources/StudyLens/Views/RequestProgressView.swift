import SwiftUI

struct RequestProgressView: View {
    let progress: RequestProgress
    let isWorking: Bool
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("\(progress.stage.title) · \(String(format: "%.1f", progress.elapsed()))초")
                    .font(.caption.monospacedDigit())
            }
            if isWorking { Button("현재 요청 취소", action: cancel) }
            DisclosureGroup("요청 시간 확인") {
                Text(progress.diagnostics).font(.caption).textSelection(.enabled)
            }
            .font(.caption)
        }
    }
}
