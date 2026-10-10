//! Picks the single code block "코드 바로 복사" may put on the clipboard. Prose, ambiguous
//! multiple blocks and partially generated answers are never copied.

use crate::document::{self, Block};
use regex::Regex;
use std::sync::LazyLock;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum QuickCodeError {
    #[error("AI 응답에 복사할 코드가 없습니다. 결과에서 추가 정보 요청 등 실제 내용을 확인하세요. 기존 클립보드는 유지했습니다.")]
    NoCode,
    #[error("AI가 코드 블록 {0}개를 반환해 자동 복사를 보류했습니다. 결과에서 필요한 블록을 직접 복사하세요.")]
    MultipleCodeBlocks(usize),
    #[error("코드 블록이 끝까지 닫히지 않아 복사하지 않았습니다. 결과를 확인하세요.")]
    IncompleteCode,
    #[error("AI가 빈 코드 블록을 반환해 복사하지 않았습니다.")]
    EmptyCode,
}

pub struct Extracted {
    pub block: Block,
}

pub fn extract(response: &str) -> Result<Extracted, QuickCodeError> {
    let response = normalize_complete_java_source(response);
    let mut code: Vec<Block> = document::parse(&response).into_iter().filter(Block::is_code).collect();
    match code.len() {
        0 => return Err(QuickCodeError::NoCode),
        1 => {}
        n => return Err(QuickCodeError::MultipleCodeBlocks(n)),
    }
    let block = code.remove(0);
    if !block.is_complete {
        return Err(QuickCodeError::IncompleteCode);
    }
    if block.text.trim().is_empty() {
        return Err(QuickCodeError::EmptyCode);
    }
    Ok(Extracted { block })
}

static JAVA_CLASS_START: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\A\s*(?:(?://[^\n]*\n|/\*[\s\S]*?\*/|package\s+[\w.]+\s*;|import\s+(?:static\s+)?[\w.*]+\s*;)\s*)*(?:(?:public|final|abstract)\s+)*class\s+[A-Za-z_$][\w$]*\b").unwrap()
});

/// Accept a standalone Java class even if the model omitted Markdown fences.
/// This is a shape check, not a compile check.
pub fn normalize_complete_java_source(response: &str) -> String {
    if document::parse(response).iter().any(Block::is_code) {
        return response.to_string();
    }
    let trimmed = response.trim();
    if !JAVA_CLASS_START.is_match(trimmed) || !trimmed.ends_with('}') || !balanced_java_delimiters(trimmed) {
        return response.to_string();
    }
    let longest = trimmed.lines().map(|l| l.chars().take_while(|c| *c == '`').count()).max().unwrap_or(0);
    let fence = "`".repeat((longest + 1).max(3));
    let newline = if response.ends_with('\n') { "" } else { "\n" };
    format!("{fence}java\n{response}{newline}{fence}")
}

fn balanced_java_delimiters(source: &str) -> bool {
    let chars: Vec<char> = source.chars().collect();
    let mut stack = Vec::new();
    let mut quote: Option<char> = None;
    let (mut block_comment, mut line_comment) = (false, false);
    let mut i = 0;
    while i < chars.len() {
        let ch = chars[i];
        let next = chars.get(i + 1).copied();
        if line_comment {
            if ch == '\n' {
                line_comment = false;
            }
        } else if block_comment {
            if ch == '*' && next == Some('/') {
                block_comment = false;
                i += 1;
            }
        } else if let Some(active) = quote {
            if ch == '\\' {
                i += 1;
            } else if ch == active {
                quote = None;
            }
        } else if ch == '/' && next == Some('/') {
            line_comment = true;
            i += 1;
        } else if ch == '/' && next == Some('*') {
            block_comment = true;
            i += 1;
        } else if ch == '"' || ch == '\'' {
            quote = Some(ch);
        } else if "([{".contains(ch) {
            stack.push(ch);
        } else if let Some(open) = match ch { ')' => Some('('), ']' => Some('['), '}' => Some('{'), _ => None } {
            if stack.pop() != Some(open) {
                return false;
            }
        }
        i += 1;
    }
    stack.is_empty() && quote.is_none() && !block_comment
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copies_only_the_complete_code_block() {
        let code = "class Solution {\n    // 줄바꿈 보존\n\tint x = 1;\n}\n";
        let extracted = extract(&format!("설명\n```java\n{code}```\n설명 끝")).unwrap();
        assert_eq!(extracted.block.id, 1);
        assert_eq!(extracted.block.text, code);
    }

    #[test]
    fn rejects_missing_multiple_unclosed_and_empty_code() {
        assert_eq!(extract("추가 정보가 필요합니다").err(), Some(QuickCodeError::NoCode));
        assert_eq!(extract("```java\nint x;").err(), Some(QuickCodeError::IncompleteCode));
        assert_eq!(extract("```java\nint x;\n```\n```java\nint y;\n```").err(), Some(QuickCodeError::MultipleCodeBlocks(2)));
        assert_eq!(extract("```java\n\n```").err(), Some(QuickCodeError::EmptyCode));
        assert_eq!(extract("```java\n```").err(), Some(QuickCodeError::EmptyCode));
    }

    #[test]
    fn crlf_java_with_line_comments_is_recognised_without_changing_line_endings() {
        let code = "// 가정\r\nclass Solution {\r\n    // } 괄호 주석\r\n    int x = 1;\r\n}\r\n";
        let extracted = extract(code).unwrap();
        assert_eq!(extracted.block.text, code);
    }

    #[test]
    fn standalone_java_without_markdown_is_copied_verbatim() {
        let code = "// 필요한 가정\nimport java.util.*;\nclass Solution {\n\tString s = \"}\\\"\";\n    /* { */ int x = 1;\n}\n";
        let extracted = extract(code).unwrap();
        assert_eq!(extracted.block.text, code);
    }

    #[test]
    fn prose_and_unbalanced_java_stay_uncopied() {
        for response in [
            "아래 코드를 사용하세요.\nclass Solution {}",
            "class Solution {\nvoid solve() {\n}",
            "추가 그림이 필요합니다",
            "class Solution { String s = \"unfinished; }",
        ] {
            assert_eq!(extract(response).err(), Some(QuickCodeError::NoCode), "{response}");
        }
    }
}
