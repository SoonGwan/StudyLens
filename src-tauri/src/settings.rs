//! User preferences, stored as JSON in the app config directory. Secrets are not here.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BillingMode {
    ClaudeCode,
    ChatGpt,
    ApiKey,
}

impl BillingMode {
    pub fn model(self, settings: &Settings) -> String {
        match self {
            BillingMode::ClaudeCode => &settings.claude_model,
            BillingMode::ChatGpt => &settings.chatgpt_model,
            BillingMode::ApiKey => &settings.api_model,
        }
        .trim()
        .to_string()
    }

    pub fn title(self) -> &'static str {
        match self {
            BillingMode::ClaudeCode => "Claude 구독 (Claude Code)",
            BillingMode::ChatGpt => "ChatGPT 구독",
            BillingMode::ApiKey => "OpenAI API 키",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Shortcuts {
    pub capture: String,
    pub text: String,
    pub code: String,
}

impl Default for Shortcuts {
    fn default() -> Self {
        Self {
            capture: "CommandOrControl+Shift+9".into(),
            text: "CommandOrControl+Shift+0".into(),
            code: "CommandOrControl+Shift+8".into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub billing_mode: BillingMode,
    pub shortcuts: Shortcuts,
    pub code_language: String,
    pub api_model: String,
    pub chatgpt_model: String,
    pub claude_model: String,
    pub claude_path: String,
    /// Reasoning effort per `mode:model` (see `inference::capabilities`).
    pub reasoning: BTreeMap<String, String>,
    /// Text and code requests also ask for a picture region (OpenAI connections only).
    pub attach_image: bool,
    /// Sent after the selection as "추가 지시".
    pub additional_instructions: String,
    /// Stable per-install identifier sent when registering a ChatGPT connection.
    pub host_id: String,
    pub onboarded: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            billing_mode: BillingMode::ClaudeCode,
            shortcuts: Shortcuts::default(),
            code_language: "Java".into(),
            api_model: "gpt-4.1-mini".into(),
            chatgpt_model: String::new(),
            claude_model: String::new(),
            claude_path: String::new(),
            reasoning: BTreeMap::new(),
            attach_image: false,
            additional_instructions: String::new(),
            host_id: format!("urn:uuid:{}", uuid::Uuid::new_v4()),
            onboarded: false,
        }
    }
}

pub const CODE_LANGUAGES: &[&str] = &["Java", "Python", "C++", "C", "JavaScript", "TypeScript", "Swift", "Kotlin", "Go", "Rust"];

pub fn path(config_dir: &Path) -> PathBuf {
    config_dir.join("settings.json")
}

pub fn load(path: &Path) -> Settings {
    let settings = std::fs::read(path).ok().and_then(|data| serde_json::from_slice(&data).ok());
    let settings: Settings = settings.unwrap_or_default();
    // Write back so generated defaults (the host id in particular) stay stable.
    let _ = save(path, &settings);
    settings
}

pub fn save(path: &Path, settings: &Settings) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let data = serde_json::to_vec_pretty(settings).map_err(|e| e.to_string())?;
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, data).map_err(|e| e.to_string())?;
    std::fs::rename(&temporary, path).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_fills_missing_fields() {
        let dir = std::env::temp_dir().join(format!("sl-settings-{}", uuid::Uuid::new_v4()));
        let file = path(&dir);
        let first = load(&file);
        assert!(file.exists());
        assert_eq!(load(&file).host_id, first.host_id);
        std::fs::write(&file, r#"{"billingMode":"chatGpt","codeLanguage":"Go"}"#).unwrap();
        let partial = load(&file);
        assert_eq!(load(&file).host_id, partial.host_id);
        assert_eq!(partial.billing_mode, BillingMode::ChatGpt);
        assert_eq!(partial.code_language, "Go");
        assert_eq!(partial.shortcuts, Shortcuts::default());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
