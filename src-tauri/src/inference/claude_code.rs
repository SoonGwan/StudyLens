//! Runs the user's own Claude Code CLI headlessly (`claude -p`), so requests use the
//! subscription Claude Code is signed in with. StudyLens never reads Claude Code's tokens.

use super::{capabilities, prompts, InferenceError, InferenceProvider};
use async_trait::async_trait;
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

pub const MODELS: &[(&str, &str)] = &[("", "Claude Code 기본값"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")];

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeStatus {
    pub logged_in: bool,
    #[serde(default)]
    pub auth_method: Option<String>,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub subscription_type: Option<String>,
}

#[derive(Clone, Default)]
pub struct ClaudeCode {
    /// Empty means "find claude automatically".
    pub executable_path: String,
    /// Empty means Claude Code's default model.
    pub model: String,
    /// Sent after the selection as "추가 지시".
    pub additional_instructions: String,
}

struct Output {
    status: Option<i32>,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

impl ClaudeCode {
    pub async fn status(&self) -> Result<ClaudeStatus, InferenceError> {
        let output = self.run(&["auth", "status", "--json"], None, Duration::from_secs(30)).await?;
        serde_json::from_slice(&output.stdout).map_err(|_| InferenceError::Claude(trimmed(&output.stderr).unwrap_or("로그인 상태를 읽지 못했습니다.".into())))
    }

    /// Claude Code opens the browser and handles the sign-in itself.
    pub async fn login(&self) -> Result<(), InferenceError> {
        let output = self.run(&["auth", "login", "--claudeai"], None, Duration::from_secs(600)).await?;
        if output.status == Some(0) {
            return Ok(());
        }
        Err(InferenceError::Claude(trimmed(&output.stderr).or(trimmed(&output.stdout)).unwrap_or("로그인하지 못했습니다.".into())))
    }

    /// Fails fast before a capture starts.
    pub async fn check_installed(&self) -> Result<(), InferenceError> {
        let path = self.executable_path.clone();
        tokio::task::spawn_blocking(move || locate_executable(&path)).await.map_err(|_| InferenceError::ClaudeNotInstalled)??;
        Ok(())
    }

    async fn perform(&self, content: Vec<Value>, system_prompt: &str) -> Result<String, InferenceError> {
        let arguments = arguments(system_prompt, &self.model);
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        let output = self.run(&arguments, Some(input_line(content)), Duration::from_secs(300)).await?;
        parse_result(&output.stdout, &output.stderr)
    }

    async fn run(&self, arguments: &[&str], input: Option<Vec<u8>>, timeout: Duration) -> Result<Output, InferenceError> {
        let path = self.executable_path.clone();
        let executable = tokio::task::spawn_blocking(move || locate_executable(&path))
            .await
            .map_err(|_| InferenceError::ClaudeNotInstalled)??;
        let mut command = Command::new(&executable);
        command
            .args(arguments)
            .current_dir(std::env::temp_dir())
            .stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            // Dropping the future (cancel, timeout) must not leave claude running.
            .kill_on_drop(true);
        if let Some(directory) = executable.parent() {
            let path = std::env::var_os("PATH").unwrap_or_default();
            let mut paths = vec![directory.to_path_buf()];
            paths.extend(std::env::split_paths(&path));
            if let Ok(joined) = std::env::join_paths(paths) {
                command.env("PATH", joined);
            }
        }
        #[cfg(windows)]
        {
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            command.creation_flags(CREATE_NO_WINDOW);
        }
        let mut child = command.spawn().map_err(|_| InferenceError::ClaudeNotInstalled)?;
        if let Some(input) = input {
            let mut stdin = child.stdin.take().expect("piped stdin");
            tokio::spawn(async move {
                let _ = stdin.write_all(&input).await;
                let _ = stdin.shutdown().await;
            });
        }
        let output = tokio::time::timeout(timeout, child.wait_with_output())
            .await
            .map_err(|_| InferenceError::TimedOut)?
            .map_err(|e| InferenceError::Claude(e.to_string()))?;
        Ok(Output { status: output.status.code(), stdout: output.stdout, stderr: output.stderr })
    }
}

#[async_trait]
impl InferenceProvider for ClaudeCode {
    async fn explain_image(&self, png: &[u8]) -> Result<String, InferenceError> {
        let data = base64::engine::general_purpose::STANDARD.encode(png);
        let image = json!({ "type": "image", "source": { "type": "base64", "media_type": "image/png", "data": data } });
        self.perform(vec![image, text_block(prompts::IMAGE_REQUEST)], prompts::INSTRUCTIONS).await
    }

    async fn explain_text(&self, text: &str) -> Result<String, InferenceError> {
        self.perform(self.selection_content(text)?, prompts::INSTRUCTIONS).await
    }

    async fn generate_code(&self, text: &str, language: &str) -> Result<String, InferenceError> {
        self.perform(self.selection_content(text)?, &prompts::code_instructions(language)).await
    }

    async fn generate_code_from_image(&self, png: &[u8], language: &str) -> Result<String, InferenceError> {
        self.perform(self.image_code_content(png)?, &prompts::code_instructions(language)).await
    }
}

impl ClaudeCode {
    fn image_code_content(&self, png: &[u8]) -> Result<Vec<Value>, InferenceError> {
        capabilities::validate_png(png)?;
        let mut content = self.selection_content(prompts::IMAGE_CODE_REQUEST)?;
        let data = base64::engine::general_purpose::STANDARD.encode(png);
        content.push(json!({ "type": "image", "source": { "type": "base64", "media_type": "image/png", "data": data } }));
        Ok(content)
    }

    fn selection_content(&self, text: &str) -> Result<Vec<Value>, InferenceError> {
        capabilities::validate_text(text, &self.additional_instructions)?;
        let mut content = vec![text_block(text)];
        if !self.additional_instructions.trim().is_empty() {
            content.push(text_block(&format!("추가 지시:\n{}", self.additional_instructions)));
        }
        Ok(content)
    }
}

fn text_block(text: &str) -> Value {
    json!({ "type": "text", "text": text })
}

/// Isolated from the user's settings, MCP servers, skills and tools: one text-only turn.
pub fn arguments(system_prompt: &str, model: &str) -> Vec<String> {
    let mut arguments: Vec<String> = [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--tools", "",
        "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "", "--no-session-persistence",
        "--system-prompt", system_prompt,
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    let model = model.trim();
    if !model.is_empty() {
        arguments.extend(["--model".to_string(), model.to_string()]);
    }
    arguments
}

pub fn input_line(content: Vec<Value>) -> Vec<u8> {
    let message = json!({ "type": "user", "message": { "role": "user", "content": content } });
    let mut line = serde_json::to_vec(&message).expect("serializable");
    line.push(b'\n');
    line
}

pub fn parse_result(stdout: &[u8], stderr: &[u8]) -> Result<String, InferenceError> {
    let text = String::from_utf8_lossy(stdout);
    let result = text
        .lines()
        .rev()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .find(|value| value["type"] == "result");
    let Some(result) = result else {
        let message = trimmed(stderr).unwrap_or("응답을 읽지 못했습니다.".into());
        let lower = message.to_lowercase();
        if lower.contains("login") || lower.contains("log in") {
            return Err(InferenceError::ClaudeNotLoggedIn);
        }
        return Err(InferenceError::Claude(message));
    };
    let text = result["result"].as_str().unwrap_or_default().trim().to_string();
    if result["is_error"] == true {
        if result["api_error_status"] == 401 {
            return Err(InferenceError::ClaudeNotLoggedIn);
        }
        let message = if text.is_empty() { trimmed(stderr).unwrap_or("요청이 실패했습니다.".into()) } else { text };
        return Err(InferenceError::Claude(message));
    }
    if text.is_empty() {
        return Err(InferenceError::EmptyOutput);
    }
    Ok(text)
}

fn trimmed(data: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(data).trim().chars().take(500).collect::<String>();
    (!text.is_empty()).then_some(text)
}

static CACHED: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Apps launched from Finder or the Start menu don't inherit the shell PATH, so check the
/// usual install locations and then ask the user's shell.
pub fn locate_executable(custom: &str) -> Result<PathBuf, InferenceError> {
    let custom = custom.trim();
    if !custom.is_empty() {
        let path = expand_home(custom);
        return if is_executable(&path) { Ok(path) } else { Err(InferenceError::ClaudeNotInstalled) };
    }
    if let Some(cached) = CACHED.lock().unwrap().clone().filter(|p| is_executable(p)) {
        return Ok(cached);
    }
    let home = home_dir();
    let found = candidates(&home).into_iter().find(|p| is_executable(p)).or_else(shell_lookup).ok_or(InferenceError::ClaudeNotInstalled)?;
    *CACHED.lock().unwrap() = Some(found.clone());
    Ok(found)
}

pub fn candidates(home: &Path) -> Vec<PathBuf> {
    let mut list = Vec::new();
    if cfg!(windows) {
        list.push(home.join(".local/bin/claude.exe"));
        if let Some(appdata) = std::env::var_os("APPDATA") {
            list.push(PathBuf::from(appdata).join("npm/claude.cmd"));
        }
        return list;
    }
    list.extend([home.join(".local/bin/claude"), home.join(".claude/local/claude"), "/opt/homebrew/bin/claude".into(), "/usr/local/bin/claude".into()]);
    // nvm installs global packages per Node version; prefer the newest.
    let nvm = home.join(".nvm/versions/node");
    let mut versions: Vec<String> = std::fs::read_dir(&nvm)
        .map(|entries| entries.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    versions.sort_by(|a, b| version_key(b).cmp(&version_key(a)));
    list.extend(versions.iter().map(|v| nvm.join(v).join("bin/claude")));
    list.extend([home.join(".volta/bin/claude"), home.join(".bun/bin/claude"), home.join(".npm-global/bin/claude")]);
    list
}

fn version_key(name: &str) -> Vec<u64> {
    name.trim_start_matches('v').split('.').map(|p| p.parse().unwrap_or(0)).collect()
}

/// Non-interactive on purpose: an interactive shell without a terminal can block forever.
fn shell_lookup() -> Option<PathBuf> {
    let mut command = if cfg!(windows) {
        let mut c = std::process::Command::new("where");
        c.arg("claude");
        c
    } else {
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
        let mut c = std::process::Command::new(shell);
        c.args(["-lc", "command -v claude"]);
        c
    };
    command.stdin(Stdio::null()).stderr(Stdio::null()).stdout(Stdio::piped());
    let mut child = command.spawn().ok()?;
    let started = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < Duration::from_secs(5) => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                return None;
            }
        }
    }
    let output = child.wait_with_output().ok()?;
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|l| PathBuf::from(l.trim()))
        .filter(|p| p.is_absolute() && is_executable(p))
        .last()
}

fn home_dir() -> PathBuf {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from).unwrap_or_default()
}

fn expand_home(path: &str) -> PathBuf {
    match path.strip_prefix("~/") {
        Some(rest) => home_dir().join(rest),
        None => PathBuf::from(path),
    }
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata().map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inference::capabilities::InputError;

    #[test]
    fn image_code_message_contains_only_selected_png_and_instructions() {
        let claude = ClaudeCode { additional_instructions: "solution 함수로".into(), ..Default::default() };
        let mut png = Vec::new();
        image::DynamicImage::new_rgba8(2, 3).write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        let content = claude.image_code_content(&png).unwrap();
        assert_eq!(content.len(), 3);
        assert_eq!(content[0]["text"], prompts::IMAGE_CODE_REQUEST);
        assert_eq!(content[1]["text"], "추가 지시:\nsolution 함수로");
        assert_eq!(content[2]["source"]["media_type"], "image/png");
        let decoded = base64::engine::general_purpose::STANDARD.decode(content[2]["source"]["data"].as_str().unwrap()).unwrap();
        assert_eq!(decoded, png);
        assert!(matches!(claude.image_code_content(b"bad png"), Err(InferenceError::Input(InputError::InvalidImage))));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn image_code_executes_cli_with_code_prompt_not_explanation_prompt() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("sl-image-code-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("claude");
        std::fs::write(&script, "#!/bin/sh\ninput=$(cat)\ncase \"$* $input\" in\n  *'기본 언어 Java'*'\"media_type\":\"image/png\"'*) printf '%s\\n' '{\"type\":\"result\",\"is_error\":false,\"result\":\"```java\\nclass Solution {}\\n```\"}' ;;\n  *) printf '%s\\n' '{\"type\":\"result\",\"is_error\":true,\"result\":\"잘못된 요청\"}' ;;\nesac\n").unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        let claude = ClaudeCode { executable_path: script.to_string_lossy().into_owned(), ..Default::default() };
        let mut png = Vec::new();
        image::DynamicImage::new_rgba8(2, 2).write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        assert_eq!(claude.generate_code_from_image(&png, "Java").await.unwrap(), "```java\nclass Solution {}\n```");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn arguments_isolate_user_setup_and_disable_tools() {
        let args = arguments("지침", " sonnet ");
        let after = |flag: &str| args[args.iter().position(|a| a == flag).unwrap() + 1].clone();
        assert_eq!(args[0], "-p");
        for flag in ["--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"] {
            assert!(args.iter().any(|a| a == flag), "{flag}");
        }
        assert_eq!(after("--tools"), "");
        assert_eq!(after("--setting-sources"), "");
        assert_eq!(after("--system-prompt"), "지침");
        assert_eq!(args[args.len() - 2..], ["--model", "sonnet"]);
        assert!(!arguments("지침", "").iter().any(|a| a == "--model"));
    }

    #[test]
    fn input_line_carries_image_block() {
        let line = input_line(vec![json!({"type":"image","source":{"type":"base64","media_type":"image/png","data":"AQID"}}), text_block("설명")]);
        assert_eq!(line.last(), Some(&b'\n'));
        let value: Value = serde_json::from_slice(&line).unwrap();
        assert_eq!(value["type"], "user");
        assert_eq!(value["message"]["content"][0]["source"]["data"], "AQID");
        assert_eq!(value["message"]["content"][1]["text"], "설명");
    }

    #[test]
    fn parse_result_returns_final_text() {
        let stdout = "{\"type\":\"system\"}\n{\"type\":\"assistant\"}\n{\"type\":\"result\",\"is_error\":false,\"result\":\"  최종 설명\\n\"}\n";
        assert_eq!(parse_result(stdout.as_bytes(), b"").unwrap(), "최종 설명");
    }

    #[test]
    fn parse_result_surfaces_errors() {
        let model = br#"{"type":"result","is_error":true,"api_error_status":404,"result":"bad model"}"#;
        assert_eq!(parse_result(model, b"").unwrap_err(), InferenceError::Claude("bad model".into()));
        let auth = br#"{"type":"result","is_error":true,"api_error_status":401,"result":"Invalid API key"}"#;
        assert_eq!(parse_result(auth, b"").unwrap_err(), InferenceError::ClaudeNotLoggedIn);
        assert_eq!(parse_result(b"", b"Not logged in \xc2\xb7 Please run /login").unwrap_err(), InferenceError::ClaudeNotLoggedIn);
        assert_eq!(parse_result(br#"{"type":"result","is_error":false,"result":""}"#, b"").unwrap_err(), InferenceError::EmptyOutput);
    }

    #[test]
    fn status_decodes_claude_code_json() {
        let status: ClaudeStatus = serde_json::from_str(r#"{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.c","subscriptionType":"max"}"#).unwrap();
        assert!(status.logged_in);
        assert_eq!(status.subscription_type.as_deref(), Some("max"));
    }

    #[cfg(unix)]
    #[test]
    fn nvm_candidates_prefer_newest_node() {
        let home = std::env::temp_dir().join(format!("sl-{}", uuid::Uuid::new_v4()));
        for v in ["v9.0.0", "v22.23.2", "v18.1.0"] {
            std::fs::create_dir_all(home.join(".nvm/versions/node").join(v).join("bin")).unwrap();
        }
        let list = candidates(&home);
        let nvm: Vec<_> = list.iter().filter_map(|p| p.to_str()).filter(|p| p.contains(".nvm")).map(|p| p.split('/').rev().nth(2).unwrap().to_string()).collect();
        assert_eq!(nvm, ["v22.23.2", "v18.1.0", "v9.0.0"]);
        std::fs::remove_dir_all(home).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn runs_configured_executable_with_stdin_message() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("sl-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("claude");
        std::fs::write(
            &script,
            "#!/bin/sh\ninput=$(cat)\ncase \"$input\" in\n  *'\"text\":\"선택한 문제\"'*) echo '{\"type\":\"result\",\"is_error\":false,\"result\":\"받음\"}' ;;\n  *) echo '{\"type\":\"result\",\"is_error\":true,\"result\":\"입력 없음\"}' ;;\nesac\n",
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut claude = ClaudeCode { executable_path: script.to_string_lossy().into_owned(), ..Default::default() };
        assert_eq!(claude.explain_text("선택한 문제").await.unwrap(), "받음");
        claude.additional_instructions = "a".repeat(2001);
        assert!(matches!(claude.explain_text("선택한 문제").await, Err(InferenceError::Input(_))));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn missing_configured_executable_is_reported() {
        assert_eq!(locate_executable("/nonexistent/claude").unwrap_err(), InferenceError::ClaudeNotInstalled);
    }
}
