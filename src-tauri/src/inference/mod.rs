//! Backends that answer StudyLens requests. The controller builds one provider
//! per request from the selected billing mode, so a new backend only needs to implement
//! [`InferenceProvider`].

pub mod capabilities;
pub mod claude_code;
pub mod openai;
pub mod prompts;
pub mod sse;

use async_trait::async_trait;

/// Timing milestones a provider reports while a response streams in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Progress {
    FirstEvent,
    FirstText,
    Completed,
}

pub type ProgressFn = std::sync::Arc<dyn Fn(Progress) + Send + Sync>;

#[async_trait]
pub trait InferenceProvider: Send + Sync {
    async fn explain_image(&self, png: &[u8]) -> Result<String, InferenceError>;
    async fn explain_text(&self, text: &str) -> Result<String, InferenceError>;
    async fn generate_code(&self, text: &str, language: &str) -> Result<String, InferenceError>;
    async fn generate_code_from_image(&self, png: &[u8], language: &str) -> Result<String, InferenceError>;
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum InferenceError {
    #[error("모델을 확인해 주세요.")]
    InvalidModel,
    #[error("응답을 읽지 못했습니다. 잠시 후 다시 시도해 주세요.")]
    InvalidResponse,
    #[error("AI가 설명을 반환하지 않았습니다. 다시 요청해 주세요.")]
    EmptyOutput,
    #[error("설명이 완료되기 전에 연결이 끊겼습니다. 다시 요청해 주세요.")]
    Interrupted,
    #[error("OpenAI API 오류({status}): {message}")]
    OpenAI { status: u16, message: String },
    #[error("네트워크 오류: {0}")]
    Network(String),
    #[error("Claude Code(claude)를 찾지 못했습니다. Claude Code를 설치하거나 설정에서 실행 파일 경로를 입력해 주세요.")]
    ClaudeNotInstalled,
    #[error("Claude Code에 로그인되어 있지 않습니다. 설정에서 Claude 로그인을 눌러 주세요.")]
    ClaudeNotLoggedIn,
    #[error("Claude 오류: {0}")]
    Claude(String),
    #[error("요청 시간이 초과되었습니다. 메뉴에서 직접 다시 요청해 주세요.")]
    TimedOut,
    #[error("{0}")]
    Input(#[from] capabilities::InputError),
}

impl From<reqwest::Error> for InferenceError {
    fn from(error: reqwest::Error) -> Self {
        if error.is_timeout() {
            InferenceError::TimedOut
        } else {
            InferenceError::Network(error.without_url().to_string())
        }
    }
}
