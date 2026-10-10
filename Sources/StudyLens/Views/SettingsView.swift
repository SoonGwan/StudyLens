import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var apiKey = ""
    @State private var message: String?
    @State private var recordingTarget: ShortcutTarget?
    @State private var shortcutMonitor: Any?

    private enum ShortcutTarget { case capture, text, code }

    var body: some View {
        Form {
            Section("전역 단축키") {
                shortcutRow("영역 캡처", value: model.captureShortcut, target: .capture)
                shortcutRow("선택 텍스트", value: model.textShortcut, target: .text)
                shortcutRow("코드 바로 복사", value: model.codeShortcut, target: .code)
                Text("기록을 누른 뒤 Command, Option 또는 Control을 포함한 조합을 입력하세요. Esc로 취소합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.shortcutError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("코드 바로 복사") {
                Picker("기본 코드 언어", selection: $model.codeLanguage) {
                    ForEach(["Java", "Python", "C++", "C", "JavaScript", "TypeScript", "Swift", "Kotlin", "Go", "Rust"], id: \.self) { Text($0).tag($0) }
                }
                .disabled(model.isWorking)
                Text("문제를 드래그하고 전용 단축키를 누르면 결과 창 없이 코드만 클립보드에 저장합니다. 본문에 언어를 지정하면 그 요청을 우선합니다. 작성이 끝난 뒤 직접 ⌘V로 붙여넣으세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("AI 연결") {
                Picker("사용 방식", selection: $model.billingMode) {
                    ForEach(BillingMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .disabled(model.isWorking || model.connectionBusy)

                if model.billingMode == .chatGPT {
                    chatGPTConnection
                } else {
                    SecureField("API 키", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("비전 지원 모델", text: $model.modelName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isWorking)
                    Text("API 사용료는 별도 청구됩니다. API 키는 macOS 키체인에 저장됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("API 키 저장") { saveAPIKey() }
                            .buttonStyle(.borderedProminent)
                        Button("키 삭제", role: .destructive) { deleteAPIKey() }
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("사용량") {
                Text(model.billingMode == .chatGPT ? "이 앱의 요청은 ChatGPT·Codex와 구독 한도를 공유합니다. 크레딧 사용 허용 여부와 앱별 한도는 ChatGPT 설정에서 관리할 수 있습니다." : "API 키 방식은 OpenAI API 플랫폼의 결제와 사용 한도를 따릅니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("ChatGPT 사용량 관리", destination: URL(string: "https://chatgpt.com/settings/usage")!)
            }

            Section("화면 기록 권한") {
                Text("영역 캡처를 위해 macOS 화면 및 시스템 오디오 기록 권한이 필요합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("시스템 설정 열기") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section("접근성 권한") {
                Text("선택한 텍스트를 읽는 기능에만 필요합니다. 키 입력이나 자동 붙여넣기에는 사용하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("손쉬운 사용 설정 열기") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section("사용 원칙") {
                Text("StudyLens는 개인 학습용입니다. 진행 중인 시험·감독 환경의 답안 제공, 앱 위장, 자동 입력 기능은 포함하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 600, height: 700)
        .onAppear { apiKey = model.loadAPIKey() }
        .onDisappear { stopShortcutRecording() }
        .alert("ChatGPT 구독 사용이 연결되었습니다", isPresented: $model.showPlanWelcome) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("이 앱의 AI 요청은 기존 ChatGPT 구독 사용량 또는 허용한 크레딧에서 차감됩니다. ChatGPT 설정 → 사용량에서 관리할 수 있습니다.")
        }
    }

    @ViewBuilder
    private var chatGPTConnection: some View {
        if !model.chatGPTProfiles.isEmpty {
            Picker("ChatGPT 연결", selection: Binding(
                get: { model.activeChatGPTClientID },
                set: { value in Task { await model.selectChatGPTProfile(value) } }
            )) {
                Text("계정을 선택하세요").tag("")
                ForEach(model.chatGPTProfiles) { profile in Text(profile.label).tag(profile.clientID) }
            }
            .disabled(model.connectionBusy || model.isWorking)
        }
        if model.activeChatGPTProfile?.credentials?.permitsInference == true {
            Label("ChatGPT 구독 사용 중", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if !model.chatGPTModels.isEmpty {
                Picker("모델", selection: $model.chatGPTModelName) {
                    ForEach(model.chatGPTModels) { item in Text(item.displayName).tag(item.slug) }
                }
                .disabled(model.isWorking || model.connectionBusy)
            }
            HStack {
                Button("모델 목록 새로고침") { Task { await model.refreshChatGPTModels() } }
                Button("로그아웃") { Task { await model.signOutOfChatGPT() } }
            }
            .disabled(model.connectionBusy || model.isWorking)
        } else {
            Button("Continue with ChatGPT") { Task { await model.signInWithChatGPT() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.connectionBusy || model.isWorking)
            if model.activeChatGPTProfile?.credentials != nil {
                Button("구독 사용 허용") { Task { await model.signInWithChatGPT(requestConsent: true) } }
                    .disabled(model.connectionBusy || model.isWorking)
            }
        }
        HStack {
            Button("다른 계정 또는 워크스페이스 연결") { Task { await model.signInWithChatGPT(newAccount: true) } }
                .disabled(model.connectionBusy || model.isWorking)
            if model.connectionBusy { ProgressView().controlSize(.small) }
            if model.connectionBusy { Button("로그인 취소") { model.cancelChatGPTSignIn() } }
        }
        Text("지원되는 ChatGPT Plus·Pro 계정으로 로그인하고 브라우저에서 구독 사용을 허용하세요.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if let message = model.connectionMessage {
            Text(message).font(.caption).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func shortcutRow(_ title: String, value: HotKeyConfiguration, target: ShortcutTarget) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.displayName)
                .font(.system(.body, design: .monospaced).weight(.semibold))
            Button(recordingTarget == target ? "입력 대기 중…" : "단축키 기록") {
                startShortcutRecording(target)
            }
        }
    }

    private func startShortcutRecording(_ target: ShortcutTarget) {
        if recordingTarget != nil {
            stopShortcutRecording()
        }
        recordingTarget = target
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopShortcutRecording()
                return nil
            }
            guard let shortcut = HotKeyConfiguration.from(event: event) else {
                message = "Command, Option 또는 Control을 포함해 주세요."
                return nil
            }
            let otherShortcuts = [
                (ShortcutTarget.capture, model.captureShortcut),
                (ShortcutTarget.text, model.textShortcut),
                (ShortcutTarget.code, model.codeShortcut)
            ].filter { $0.0 != target }.map { $0.1 }
            guard !otherShortcuts.contains(shortcut) else {
                message = "다른 StudyLens 기능이 사용 중인 단축키입니다. 다른 조합을 입력하세요."
                return nil
            }
            if target == .capture { model.captureShortcut = shortcut }
            if target == .text { model.textShortcut = shortcut }
            if target == .code { model.codeShortcut = shortcut }
            message = model.shortcutError ?? "단축키를 \(shortcut.displayName)(으)로 변경했습니다."
            stopShortcutRecording()
            return nil
        }
    }

    private func stopShortcutRecording() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        recordingTarget = nil
    }

    private func saveAPIKey() {
        do {
            try model.saveAPIKey(apiKey)
            message = apiKey.isEmpty ? "빈 키는 저장하지 않았습니다." : "API 키를 키체인에 저장했습니다."
        } catch {
            message = error.localizedDescription
        }
    }

    private func deleteAPIKey() {
        do {
            try model.deleteAPIKey()
            apiKey = ""
            message = "API 키를 삭제했습니다."
        } catch {
            message = error.localizedDescription
        }
    }
}
