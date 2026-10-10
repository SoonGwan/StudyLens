import AppKit
import Foundation

/// Split fenced code before interpreting Markdown so source whitespace is never rendered away.
struct ResponseDocument {
    struct Block: Identifiable, Equatable {
        let id: Int
        let text: String
        let language: String?
        let isComplete: Bool
        var isCode: Bool { language != nil }
    }

    let blocks: [Block]

    init(_ source: String) {
        var result: [Block] = []
        var lines: [String] = []
        var fence: (character: Character, count: Int, language: String)?

        func flush(language: String?, closedFence: Bool = false) {
            guard !lines.isEmpty || language != nil else { return }
            var text = lines.joined(separator: "\n")
            if closedFence && !lines.isEmpty { text += "\n" }
            if language != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(Block(id: result.count, text: text, language: language, isComplete: language == nil || closedFence))
            }
            lines.removeAll()
        }

        for line in source.components(separatedBy: "\n") {
            let candidate = Self.fenceLine(line)
            if let active = fence {
                if let candidate, candidate.character == active.character,
                   candidate.count >= active.count, candidate.info.isEmpty {
                    flush(language: active.language, closedFence: true)
                    fence = nil
                } else {
                    lines.append(line)
                }
            } else if let candidate,
                      candidate.character != "`" || !candidate.info.contains("`") {
                flush(language: nil)
                fence = (candidate.character, candidate.count,
                         candidate.info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "")
            } else {
                lines.append(line)
            }
        }
        flush(language: fence?.language)
        blocks = result
    }

    private static func fenceLine(_ line: String) -> (character: Character, count: Int, info: String)? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let content = line.dropFirst(indentation)
        guard let character = content.first, character == "`" || character == "~" else { return nil }
        let count = content.prefix(while: { $0 == character }).count
        guard count >= 3 else { return nil }
        return (character, count, content.dropFirst(count).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum ResponseClipboard {
    @MainActor
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
