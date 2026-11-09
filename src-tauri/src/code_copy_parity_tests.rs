//! The 37 synthetic expectations from Swift commit 8702612, shared with browser QA.
use crate::{document, quick_code};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Fixture {
    name: String,
    response: String,
    expected_code: Option<String>,
    error: Option<String>,
    code_blocks: Vec<ExpectedBlock>,
}

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct ExpectedBlock {
    text: String,
    is_complete: bool,
}

fn error_name(error: quick_code::QuickCodeError) -> &'static str {
    use quick_code::QuickCodeError::*;
    match error {
        NoCode => "noCode",
        EmptyCode => "emptyCode",
        IncompleteCode => "incompleteCode",
        MultipleCodeBlocks(count) => {
            assert_eq!(count, 2);
            "multipleCodeBlocks"
        }
    }
}

#[test]
fn swift_code_copy_fixtures_match_rust_extraction_and_display() {
    let fixtures: Vec<Fixture> =
        serde_json::from_str(include_str!("../../tests/fixtures/code-copy.json")).unwrap();
    assert_eq!(fixtures.len(), 37);
    let mut snapshots = Vec::new();
    for fixture in fixtures {
        let result = quick_code::extract(&fixture.response);
        assert_eq!(
            result.as_ref().ok().map(|r| &r.block.text),
            fixture.expected_code.as_ref(),
            "{}",
            fixture.name
        );
        assert_eq!(
            result.err().map(error_name),
            fixture.error.as_deref(),
            "{}",
            fixture.name
        );

        let normalized = quick_code::normalize_complete_java_source(&fixture.response);
        let blocks = document::parse(&normalized);
        let code: Vec<_> = blocks
            .iter()
            .filter(|b| b.is_code())
            .map(|b| ExpectedBlock {
                text: b.text.clone(),
                is_complete: b.is_complete,
            })
            .collect();
        assert_eq!(code, fixture.code_blocks, "{}", fixture.name);
        // Only accepted raw Java is wrapped; every other response stays verbatim.
        let expected_normalized =
            if fixture.name.starts_with("java-") && fixture.name.ends_with("-raw") {
                format!("```java\n{}```", fixture.response)
            } else {
                fixture.response.clone()
            };
        assert_eq!(normalized, expected_normalized, "{}", fixture.name);
        snapshots.push(
            serde_json::json!({ "fixture": fixture, "normalized": normalized, "blocks": blocks }),
        );
    }
    // Opt-in bridge to the browser runner: these are actual Rust output blocks,
    // not a second JavaScript implementation of the parser.
    if let Some(path) = std::env::var_os("STUDYLENS_COPY_QA_OUTPUT") {
        std::fs::write(path, serde_json::to_vec_pretty(&snapshots).unwrap()).unwrap();
    }
}
