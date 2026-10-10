import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    let openResult: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.status.symbolName)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.status.menuTitle).font(.headline)
                    Text("캡처 \(model.captureShortcut.displayName) · 텍스트 \(model.textShortcut.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(model.billingLabel).font(.caption).foregroundStyle(.secondary)
            Text("코드 바로 복사 \(model.codeShortcut.displayName)").font(.caption).foregroundStyle(.secondary)
            if let message = model.quickCopyMessage {
                Text(message).font(.caption).foregroundStyle(statusColor)
            }
            if let error = model.errorMessage { Text(error).font(.caption).textSelection(.enabled) }
            if let error = model.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }

            Button {
                Task { await model.captureAndAnalyze() }
            } label: {
                Label("영역 캡처하고 설명 받기", systemImage: "viewfinder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keyboardShortcut("c")
            .disabled(model.status == .selecting || model.status == .analyzing)

            Button {
                Task { await model.copySelectedCode() }
            } label: {
                Label("선택한 문제 → 코드 바로 복사", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.isWorking || model.connectionBusy)

            Button {
                Task { await model.analyzeSelectedText() }
            } label: {
                Label("선택한 텍스트 설명 받기", systemImage: "text.cursor")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.status == .selecting || model.status == .analyzing)

            if model.status == .ready || model.status == .failed {
                Button {
                    openResultWindow()
                } label: {
                    Label("결과 열기", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            Button {
                openSettings()
            } label: {
                Label("설정…", systemImage: "gearshape")
            }

            Button("StudyLens 종료") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 290)
        .task { model.start() }
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: return .accentColor
        case .selecting, .analyzing: return .orange
        case .ready: return .green
        case .failed: return .red
        }
    }

    private func openResultWindow() {
        openResult()
    }
}
