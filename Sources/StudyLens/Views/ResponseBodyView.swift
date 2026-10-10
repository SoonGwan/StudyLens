import SwiftUI

struct ResponseBodyView: View {
    let document: ResponseDocument
    let copiedCodeID: Int?
    let copyCode: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(document.blocks) { block in
                if block.isCode {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(block.language?.isEmpty == false ? block.language! : "코드")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                copyCode(block.id)
                            } label: {
                                Label(copiedCodeID == block.id ? "코드 복사됨" : "코드 복사",
                                      systemImage: copiedCodeID == block.id ? "checkmark" : "doc.on.doc")
                            }
                            .accessibilityLabel("코드 복사 \(block.id + 1)")
                            .disabled(!block.isComplete || block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(10)
                        Divider()
                        ScrollView(.horizontal) {
                            Text(verbatim: block.text)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                                .padding(12)
                        }
                    }
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Text(Self.prose(block.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    static func prose(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
