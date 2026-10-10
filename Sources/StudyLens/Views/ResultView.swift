import SwiftUI

struct ResultView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let image = model.capturedImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .frame(maxWidth: .infinity)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("사용자가 선택한 화면 영역")
                    }

                    if !model.selectedText.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("선택한 텍스트").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(model.selectedText)
                                .lineLimit(8)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }

                    content
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("학습 설명").font(.title2.bold())
                Text("내용을 검토한 뒤 필요한 경우에만 복사하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.resultBillingLabel.isEmpty {
                    Text(model.resultBillingLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.status == .analyzing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            Label {
                Text(error)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .textSelection(.enabled)
            if model.hasSelectionError {
                Link("손쉬운 사용 권한 설정 열기", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                Text("이 오류는 AI 요청 전에 발생했습니다. 로그인이나 사용량 문제는 아닙니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.billingMode == .chatGPT && model.explanation.isEmpty {
                Link("ChatGPT 사용량 관리", destination: URL(string: "https://chatgpt.com/settings/usage")!)
            }
            if !model.explanation.isEmpty {
                Text("AI가 반환한 응답").font(.headline)
                ResponseBodyView(document: model.responseDocument,
                                 copiedCodeID: model.copiedCodeID,
                                 copyCode: model.copyCode)
            }
        } else if model.status == .analyzing {
            VStack(alignment: .leading, spacing: 8) {
                Text("문제를 읽고 설명을 만들고 있습니다…")
                    .font(.headline)
                Text("이미지 크기와 모델에 따라 잠시 걸릴 수 있습니다.")
                    .foregroundStyle(.secondary)
            }
        } else if !model.explanation.isEmpty {
            ResponseBodyView(document: model.responseDocument,
                             copiedCodeID: model.copiedCodeID,
                             copyCode: model.copyCode)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("아직 결과가 없습니다").font(.headline)
                Text("메뉴바에서 화면 영역을 선택해 주세요.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        }
    }

    private var footer: some View {
        HStack {
            Button("새로 캡처") {
                Task { await model.captureAndAnalyze() }
            }
            .disabled(model.status == .selecting || model.status == .analyzing)

            Spacer()

            if model.copied {
                Label("복사됨", systemImage: "checkmark")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            Button {
                model.copyExplanation()
            } label: {
                Label("전체 복사", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking || model.explanation.isEmpty)

            let codeBlocks = model.responseDocument.blocks.filter(\.isCode)
            if codeBlocks.count == 1, let code = codeBlocks.first {
                Button {
                    model.copyCode(code.id)
                } label: {
                    Label(model.copiedCodeID == code.id ? "코드 복사됨" : "코드만 복사",
                          systemImage: model.copiedCodeID == code.id ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || !code.isComplete || code.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
    }
}
