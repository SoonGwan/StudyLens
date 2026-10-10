import Foundation

enum QuickCodeCopyError: LocalizedError, Equatable {
    case noCode, multipleCodeBlocks(Int), incompleteCode, emptyCode, clipboardFailed

    var errorDescription: String? {
        switch self {
        case .noCode:
            return "AI 응답에 복사할 코드가 없습니다. 아래 응답에서 추가 정보 요청 등 실제 내용을 확인하세요. 기존 클립보드는 유지했습니다."
        case .multipleCodeBlocks(let count):
            return "AI가 코드 블록 \(count)개를 반환해 자동 복사를 보류했습니다. 아래에서 필요한 블록을 직접 복사하세요."
        case .incompleteCode:
            return "코드 블록이 끝까지 닫히지 않아 복사하지 않았습니다. 아래 응답을 확인하세요."
        case .emptyCode:
            return "AI가 빈 코드 블록을 반환해 복사하지 않았습니다."
        case .clipboardFailed:
            return "코드를 클립보드에 저장하지 못했습니다."
        }
    }
}

/// Never writes prose, ambiguous multiple blocks, or a partially generated answer.
@MainActor
struct QuickCodeCopy {
    var readSelection: () async throws -> String
    var generate: (String) async throws -> String
    var write: (String) -> Bool = { ResponseClipboard.copy($0) }

    func run(onSelection: (String) -> Void = { _ in }, onResponse: (String) -> Void = { _ in },
             canCommit: () -> Bool = { true }) async throws -> Int {
        try Task.checkCancellation()
        let text = try await readSelection()
        try Task.checkCancellation()
        guard canCommit() else { throw CancellationError() }
        onSelection(text)
        let response = Self.normalizeCompleteJavaSource(try await generate(text))
        try Task.checkCancellation()
        guard canCommit() else { throw CancellationError() }
        onResponse(response)
        let blocks = ResponseDocument(response).blocks.filter(\.isCode)
        guard !blocks.isEmpty else { throw QuickCodeCopyError.noCode }
        guard blocks.count == 1 else { throw QuickCodeCopyError.multipleCodeBlocks(blocks.count) }
        let block = blocks[0]
        guard block.isComplete else { throw QuickCodeCopyError.incompleteCode }
        guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw QuickCodeCopyError.emptyCode }
        try Task.checkCancellation()
        guard canCommit() else { throw CancellationError() }
        guard write(block.text) else { throw QuickCodeCopyError.clipboardFailed }
        return block.id
    }

    /// Accept a standalone Java class even if the model omitted Markdown fences.
    /// Prose and unfinished source are not treated as a copyable answer.
    static func normalizeCompleteJavaSource(_ response: String) -> String {
        guard !ResponseDocument(response).blocks.contains(where: \.isCode) else { return response }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\A\s*(?:(?://[^\n]*\n|/\*[\s\S]*?\*/|package\s+[\w.]+\s*;|import\s+(?:static\s+)?[\w.*]+\s*;)\s*)*(?:(?:public|final|abstract)\s+)*class\s+[A-Za-z_$][\w$]*\b"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil,
              trimmed.hasSuffix("}"), balancedJavaDelimiters(trimmed) else { return response }
        let length = max(3, (trimmed.components(separatedBy: "\n").map { $0.prefix(while: { $0 == "`" }).count }.max() ?? 0) + 1)
        let fence = String(repeating: "`", count: length)
        return fence + "java\n" + response + (response.utf8.last == 10 ? "" : "\n") + fence
    }

    private static func balancedJavaDelimiters(_ source: String) -> Bool {
        let chars = Array(source)
        var stack: [Character] = []
        var quote: Character?
        var blockComment = false
        var lineComment = false
        var index = 0
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        while index < chars.count {
            let ch = chars[index]
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            if lineComment { if ch == "\n" || ch == "\r\n" || ch == "\r" { lineComment = false } }
            else if blockComment { if ch == "*", next == "/" { blockComment = false; index += 1 } }
            else if let activeQuote = quote {
                if ch == "\\" { index += 1 }
                else if ch == activeQuote { quote = nil }
            } else if ch == "/", next == "/" { lineComment = true; index += 1 }
            else if ch == "/", next == "*" { blockComment = true; index += 1 }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if "([{".contains(ch) { stack.append(ch) }
            else if let opening = pairs[ch] {
                guard stack.popLast() == opening else { return false }
            }
            index += 1
        }
        return stack.isEmpty && quote == nil && !blockComment
    }
}
