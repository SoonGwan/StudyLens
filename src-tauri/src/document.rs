//! Splits a model response into prose and fenced code blocks before any Markdown is
//! interpreted, so source whitespace is never rendered away.

use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Block {
    pub id: usize,
    pub text: String,
    /// `None` for prose, `Some("")` for a code block without an info string.
    pub language: Option<String>,
    pub is_complete: bool,
}

impl Block {
    pub fn is_code(&self) -> bool {
        self.language.is_some()
    }
}

struct Fence {
    character: char,
    count: usize,
    language: String,
}

pub fn parse(source: &str) -> Vec<Block> {
    let mut blocks: Vec<Block> = Vec::new();
    let mut lines: Vec<&str> = Vec::new();
    let mut fence: Option<Fence> = None;

    fn flush(blocks: &mut Vec<Block>, lines: &mut Vec<&str>, language: Option<String>, closed: bool) {
        if lines.is_empty() && language.is_none() {
            return;
        }
        let mut text = lines.join("\n");
        if closed && !lines.is_empty() {
            text.push('\n');
        }
        if language.is_some() || !text.trim().is_empty() {
            let is_complete = language.is_none() || closed;
            blocks.push(Block { id: blocks.len(), text, language, is_complete });
        }
        lines.clear();
    }

    for line in source.split('\n') {
        let candidate = fence_line(line);
        if let Some(active) = &fence {
            match candidate {
                Some((character, count, info)) if character == active.character && count >= active.count && info.is_empty() => {
                    let language = active.language.clone();
                    flush(&mut blocks, &mut lines, Some(language), true);
                    fence = None;
                }
                _ => lines.push(line),
            }
        } else if let Some((character, count, info)) = candidate.filter(|(c, _, info)| *c != '`' || !info.contains('`')) {
            flush(&mut blocks, &mut lines, None, false);
            let language = info.split_whitespace().next().unwrap_or("").to_string();
            fence = Some(Fence { character, count, language });
        } else {
            lines.push(line);
        }
    }
    let language = fence.map(|f| f.language);
    flush(&mut blocks, &mut lines, language, false);
    blocks
}

fn fence_line(line: &str) -> Option<(char, usize, String)> {
    let indentation = line.chars().take_while(|c| *c == ' ').count();
    if indentation > 3 {
        return None;
    }
    let content = &line[indentation..];
    let character = content.chars().next().filter(|c| *c == '`' || *c == '~')?;
    let count = content.chars().take_while(|c| *c == character).count();
    if count < 3 {
        return None;
    }
    Some((character, count, content[count..].trim().to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_prose_and_code_preserving_whitespace() {
        let blocks = parse("설명\n```java\nclass A {\n\tint x;\n}\n```\n끝");
        assert_eq!(blocks.len(), 3);
        assert_eq!(blocks[1].language.as_deref(), Some("java"));
        assert_eq!(blocks[1].text, "class A {\n\tint x;\n}\n");
        assert!(blocks[1].is_complete);
        assert_eq!(blocks[2].text, "끝");
    }

    #[test]
    fn unclosed_fence_is_incomplete() {
        let blocks = parse("```py\nprint(1)");
        assert_eq!(blocks.len(), 1);
        assert!(blocks[0].is_code());
        assert!(!blocks[0].is_complete);
    }

    #[test]
    fn closing_fence_must_match_character_and_length() {
        let blocks = parse("````\n```\ninner\n````");
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].text, "```\ninner\n");
    }

    #[test]
    fn backtick_info_with_backtick_is_not_a_fence() {
        let blocks = parse("```a`b\ntext");
        assert!(blocks.iter().all(|b| !b.is_code()));
    }

    #[test]
    fn multiple_blocks_keep_languages_and_ids() {
        let blocks = parse("```java\nint x = 1;\n```\n설명\n~~~python\nprint(2)\n~~~");
        let code: Vec<_> = blocks.iter().filter(|b| b.is_code()).map(|b| b.text.as_str()).collect();
        assert_eq!(code, ["int x = 1;\n", "print(2)\n"]);
        assert_eq!(blocks.iter().map(|b| b.id).collect::<Vec<_>>(), [0, 1, 2]);
        assert_eq!(blocks[2].language.as_deref(), Some("python"));
    }

    #[test]
    fn crlf_and_tabs_survive() {
        let code = "class Solution {\r\n\tint x;\r\n}\r\n";
        let blocks = parse(&format!("```java\r\n{code}```\r\n"));
        assert_eq!(blocks[0].text, code);
    }

    #[test]
    fn immediately_closed_fence_is_an_empty_code_block() {
        let blocks = parse("```java\n```");
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].text, "");
        assert!(blocks[0].is_code() && blocks[0].is_complete);
    }

    #[test]
    fn deep_indent_is_not_a_fence() {
        assert!(parse("    ```\ncode").iter().all(|b| !b.is_code()));
    }
}
