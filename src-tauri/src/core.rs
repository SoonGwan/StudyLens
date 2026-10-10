//! App state and the three user workflows (capture, selected text, quick code copy).
//! Windows render snapshots of this state; every change is pushed as an event.

use crate::auth::chatgpt::{ChatGptAuth, ProfileSummary};
use crate::auth::AuthError;
use crate::document::{self, Block};
use crate::inference::claude_code::{self, ClaudeCode, ClaudeStatus};
use crate::inference::openai::{ChatGptModel, Credential, CredentialKind, OpenAIClient, OpenAIProvider};
use crate::inference::{InferenceError, InferenceProvider};
use crate::platform::{self, CaptureError, SelectionError, SelectionReader};
use crate::quick_code::{self, QuickCodeError};
use crate::secrets::SecretStore;
use crate::settings::{self, BillingMode, Settings};
use crate::{hotkeys, tray, ui};
use base64::Engine;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter};
use tauri_plugin_clipboard_manager::ClipboardExt;

const API_KEY_ACCOUNT: &str = "openai-api-key";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Status {
    #[default]
    Idle,
    Selecting,
    Analyzing,
    Ready,
    Failed,
}

/// Points the result window at the fix for an error.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Hint {
    Accessibility,
    ScreenRecording,
    ChatGptUsage,
    ClaudeUsage,
    Settings,
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ResultState {
    pub status: Status,
    pub explanation: String,
    pub blocks: Vec<Block>,
    pub captured_image: Option<String>,
    pub selected_text: String,
    pub error_message: Option<String>,
    pub hint: Option<Hint>,
    pub copied: bool,
    pub copied_code_id: Option<usize>,
    pub quick_copy_message: Option<String>,
    pub billing_label: String,
}

impl ResultState {
    pub fn is_working(&self) -> bool {
        matches!(self.status, Status::Selecting | Status::Analyzing)
    }
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionState {
    pub busy: bool,
    pub message: Option<String>,
    pub chatgpt_models: Vec<ChatGptModel>,
    pub claude_status: Option<ClaudeStatus>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SettingsView {
    pub settings: Settings,
    pub has_api_key: bool,
    pub chatgpt_profiles: Vec<ProfileSummary>,
    pub active_client_id: Option<String>,
    pub connection: ConnectionState,
    pub shortcut_errors: Vec<String>,
    pub code_languages: Vec<&'static str>,
    pub claude_models: Vec<(&'static str, &'static str)>,
    pub platform: &'static str,
    pub working: bool,
}

/// A failure shown to the user, with an optional pointer to where it can be fixed.
pub struct Failure {
    message: String,
    hint: Option<Hint>,
}

impl Failure {
    fn new(message: impl ToString, hint: Option<Hint>) -> Self {
        Self { message: message.to_string(), hint }
    }
}

impl From<SelectionError> for Failure {
    fn from(error: SelectionError) -> Self {
        let hint = (error == SelectionError::PermissionDenied && cfg!(target_os = "macos")).then_some(Hint::Accessibility);
        Failure::new(error, hint)
    }
}

impl From<CaptureError> for Failure {
    fn from(error: CaptureError) -> Self {
        let hint = (error == CaptureError::PermissionDenied).then_some(Hint::ScreenRecording);
        Failure::new(error, hint)
    }
}

impl From<AuthError> for Failure {
    fn from(error: AuthError) -> Self {
        Failure::new(error, Some(Hint::Settings))
    }
}

impl From<QuickCodeError> for Failure {
    fn from(error: QuickCodeError) -> Self {
        Failure::new(error, None)
    }
}

pub struct Core {
    pub app: AppHandle,
    settings_path: PathBuf,
    settings: Mutex<Settings>,
    result: Mutex<ResultState>,
    connection: Mutex<ConnectionState>,
    shortcut_errors: Mutex<Vec<String>>,
    secrets: Arc<dyn SecretStore>,
    chatgpt: ChatGptAuth,
    openai: OpenAIClient,
    pub selection: SelectionReader,
    claude_login: Mutex<Option<tokio::task::AbortHandle>>,
}

impl Core {
    pub fn new(app: AppHandle, config_dir: PathBuf, secrets: Arc<dyn SecretStore>) -> Arc<Self> {
        let settings_path = settings::path(&config_dir);
        let settings = settings::load(&settings_path);
        let chatgpt = ChatGptAuth::new(secrets.clone(), settings.host_id.clone());
        Arc::new(Self {
            app,
            settings_path,
            settings: Mutex::new(settings),
            result: Mutex::new(ResultState::default()),
            connection: Mutex::new(ConnectionState::default()),
            shortcut_errors: Mutex::new(Vec::new()),
            secrets,
            chatgpt,
            openai: OpenAIClient::new(),
            selection: SelectionReader::default(),
            claude_login: Mutex::new(None),
        })
    }

    // MARK: snapshots

    pub fn settings(&self) -> Settings {
        self.settings.lock().unwrap().clone()
    }

    pub fn result(&self) -> ResultState {
        self.result.lock().unwrap().clone()
    }

    pub fn settings_view(&self) -> SettingsView {
        let (chatgpt_profiles, active_client_id) = self.chatgpt.profiles();
        SettingsView {
            settings: self.settings(),
            has_api_key: self.secrets.load(API_KEY_ACCOUNT).ok().flatten().is_some_and(|k| !k.is_empty()),
            chatgpt_profiles,
            active_client_id,
            connection: self.connection.lock().unwrap().clone(),
            shortcut_errors: self.shortcut_errors.lock().unwrap().clone(),
            code_languages: settings::CODE_LANGUAGES.to_vec(),
            claude_models: claude_code::MODELS.to_vec(),
            platform: if cfg!(target_os = "macos") { "macos" } else { "windows" },
            working: self.result().is_working(),
        }
    }

    fn update_result(&self, change: impl FnOnce(&mut ResultState)) {
        let snapshot = {
            let mut state = self.result.lock().unwrap();
            change(&mut state);
            state.clone()
        };
        let _ = self.app.emit("result", &snapshot);
        tray::update(&self.app, &snapshot, &self.settings());
        self.emit_settings();
    }

    fn update_connection(&self, change: impl FnOnce(&mut ConnectionState)) {
        change(&mut self.connection.lock().unwrap());
        self.emit_settings();
    }

    pub fn emit_settings(&self) {
        let _ = self.app.emit("settings", self.settings_view());
    }

    fn connection_busy(&self) -> bool {
        self.connection.lock().unwrap().busy
    }

    /// Claims the app for a workflow; returns false if one is already running.
    fn begin(&self, status: Status, message: Option<&str>) -> bool {
        let mut state = self.result.lock().unwrap();
        if state.is_working() || self.connection_busy() {
            return false;
        }
        *state = ResultState { status, quick_copy_message: message.map(str::to_string), billing_label: self.settings().billing_mode.title().into(), ..Default::default() };
        let snapshot = state.clone();
        drop(state);
        let _ = self.app.emit("result", &snapshot);
        tray::update(&self.app, &snapshot, &self.settings());
        true
    }

    fn fail(&self, failure: Failure) {
        self.update_result(|s| {
            s.status = Status::Failed;
            s.error_message = Some(failure.message);
            s.hint = failure.hint;
        });
    }

    fn usage_hint(&self) -> Option<Hint> {
        match self.settings().billing_mode {
            BillingMode::ChatGpt => Some(Hint::ChatGptUsage),
            BillingMode::ClaudeCode => Some(Hint::ClaudeUsage),
            BillingMode::ApiKey => None,
        }
    }

    fn inference_failure(&self, error: InferenceError) -> Failure {
        let hint = match error {
            InferenceError::ClaudeNotInstalled | InferenceError::ClaudeNotLoggedIn | InferenceError::InvalidModel => Some(Hint::Settings),
            _ => self.usage_hint(),
        };
        Failure::new(error, hint)
    }

    // MARK: workflows

    pub async fn capture_and_analyze(self: Arc<Self>) {
        if !self.begin(Status::Selecting, None) {
            return;
        }
        let provider = match self.provider().await {
            Ok(provider) => provider,
            Err(failure) => return self.fail_and_show(failure),
        };
        let png = match platform::capture_region(&self.app).await {
            Ok(png) => png,
            Err(CaptureError::Cancelled) => return self.update_result(|s| s.status = Status::Idle),
            Err(error) => return self.fail_and_show(error.into()),
        };
        let image = format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(&png));
        self.update_result(|s| {
            s.captured_image = Some(image);
            s.status = Status::Analyzing;
        });
        ui::show_result(&self.app);
        match provider.explain_image(&png).await {
            Ok(text) => self.finish(text),
            Err(error) => self.fail(self.inference_failure(error)),
        }
    }

    pub async fn analyze_selected_text(self: Arc<Self>) {
        if !self.begin(Status::Selecting, None) {
            return;
        }
        // Read the selection before anything else can move focus.
        let text = match self.selection.read(true).await {
            Ok(text) => text,
            Err(error) => return self.fail_and_show(error.into()),
        };
        self.update_result(|s| {
            s.selected_text = text.clone();
            s.status = Status::Analyzing;
        });
        let provider = match self.provider().await {
            Ok(provider) => provider,
            Err(failure) => return self.fail_and_show(failure),
        };
        ui::show_result(&self.app);
        match provider.explain_text(&text).await {
            Ok(answer) => self.finish(answer),
            Err(error) => self.fail(self.inference_failure(error)),
        }
    }

    /// Never opens the result window, on success or failure: progress shows in the tray.
    pub async fn copy_selected_code(self: Arc<Self>) {
        if !self.begin(Status::Selecting, Some("선택한 텍스트 읽는 중…")) {
            return;
        }
        ui::hide_result(&self.app);
        let fail = |core: &Self, failure: Failure| {
            core.update_result(|s| s.quick_copy_message = Some("복사하지 못했습니다 · 메뉴에서 결과 확인".into()));
            core.fail(failure);
        };
        let text = match self.selection.read(false).await {
            Ok(text) => text,
            Err(error) => return fail(&self, error.into()),
        };
        self.update_result(|s| {
            s.selected_text = text.clone();
            s.status = Status::Analyzing;
            s.quick_copy_message = Some("코드 작성 중… 완료되면 클립보드에 복사합니다.".into());
        });
        let provider = match self.provider().await {
            Ok(provider) => provider,
            Err(failure) => return fail(&self, failure),
        };
        let language = self.settings().code_language;
        let response = match provider.generate_code(&text, &language).await {
            Ok(response) => response,
            Err(error) => return fail(&self, self.inference_failure(error)),
        };
        match quick_code::extract(&response) {
            Ok(extracted) => {
                if self.app.clipboard().write_text(extracted.block.text.clone()).is_err() {
                    self.set_explanation(&extracted.response);
                    return fail(&self, Failure::new("코드를 클립보드에 저장하지 못했습니다.", None));
                }
                let paste = if cfg!(target_os = "macos") { "⌘V" } else { "Ctrl+V" };
                self.set_explanation(&extracted.response);
                self.update_result(|s| {
                    s.copied_code_id = Some(extracted.block.id);
                    s.quick_copy_message = Some(format!("코드 복사 완료 · {paste}로 붙여넣기"));
                    s.status = Status::Ready;
                });
            }
            Err(error) => {
                // Keep the real answer (e.g. a request for missing details) for manual review.
                self.set_explanation(&quick_code::normalize_complete_java_source(&response));
                fail(&self, error.into());
            }
        }
    }

    fn set_explanation(&self, text: &str) {
        let blocks = document::parse(text);
        self.update_result(|s| {
            s.explanation = text.to_string();
            s.blocks = blocks;
        });
    }

    fn finish(&self, text: String) {
        self.set_explanation(&text);
        self.update_result(|s| s.status = Status::Ready);
    }

    fn fail_and_show(&self, failure: Failure) {
        self.fail(failure);
        ui::show_result(&self.app);
    }

    async fn provider(&self) -> Result<Box<dyn InferenceProvider>, Failure> {
        let settings = self.settings();
        match settings.billing_mode {
            BillingMode::ClaudeCode => {
                let claude = ClaudeCode { executable_path: settings.claude_path, model: settings.claude_model };
                claude.check_installed().await.map_err(|e| self.inference_failure(e))?;
                Ok(Box::new(claude))
            }
            BillingMode::ApiKey => {
                let key = self.secrets.load(API_KEY_ACCOUNT).map_err(|e| Failure::new(e, None))?.unwrap_or_default();
                if key.is_empty() {
                    return Err(Failure::new("OpenAI API 키가 저장되지 않았습니다. 설정에서 키를 저장해 주세요.", Some(Hint::Settings)));
                }
                let credential = Credential { token: key, kind: CredentialKind::ApiKey };
                Ok(Box::new(OpenAIProvider { client: self.openai.clone(), credential, model: settings.api_model }))
            }
            BillingMode::ChatGpt => {
                let token = self.chatgpt.access_token().await?;
                if self.connection.lock().unwrap().chatgpt_models.is_empty() {
                    self.load_chatgpt_models(&token).await.map_err(|e| self.inference_failure(e))?;
                }
                let model = self.settings().chatgpt_model;
                if !self.connection.lock().unwrap().chatgpt_models.iter().any(|m| m.slug == model) {
                    return Err(self.inference_failure(InferenceError::InvalidModel));
                }
                let credential = Credential { token, kind: CredentialKind::ChatGpt };
                Ok(Box::new(OpenAIProvider { client: self.openai.clone(), credential, model }))
            }
        }
    }

    // MARK: result window actions

    pub fn copy_explanation(&self) {
        let state = self.result();
        if state.is_working() || state.explanation.is_empty() {
            return;
        }
        let copied = self.app.clipboard().write_text(state.explanation).is_ok();
        self.update_result(|s| {
            s.copied = copied;
            s.copied_code_id = None;
        });
    }

    pub fn copy_code(&self, id: usize) {
        let state = self.result();
        let Some(block) = state.blocks.iter().find(|b| b.id == id && b.is_code() && b.is_complete && !b.text.trim().is_empty()) else { return };
        if state.is_working() {
            return;
        }
        let copied = self.app.clipboard().write_text(block.text.clone()).is_ok();
        self.update_result(|s| {
            s.copied_code_id = copied.then_some(id);
            s.copied = false;
        });
    }

    pub fn restore_explanation(&self, text: String) {
        self.set_explanation(&text);
        self.update_result(|s| s.status = Status::Ready);
    }

    // MARK: settings

    pub fn save_settings(&self, mut next: Settings) -> Result<(), String> {
        let previous = self.settings();
        next.host_id = previous.host_id.clone();
        let shortcuts = [&next.shortcuts.capture, &next.shortcuts.text, &next.shortcuts.code];
        if shortcuts.iter().enumerate().any(|(i, a)| shortcuts.iter().skip(i + 1).any(|b| a == b)) {
            return Err("다른 StudyLens 기능이 사용 중인 단축키입니다. 다른 조합을 입력하세요.".into());
        }
        settings::save(&self.settings_path, &next)?;
        let shortcuts_changed = next.shortcuts != previous.shortcuts;
        *self.settings.lock().unwrap() = next;
        if shortcuts_changed {
            self.register_shortcuts();
        }
        tray::update(&self.app, &self.result(), &self.settings());
        self.emit_settings();
        Ok(())
    }

    pub fn register_shortcuts(&self) {
        let errors = hotkeys::register(&self.app, &self.settings().shortcuts);
        *self.shortcut_errors.lock().unwrap() = errors;
        self.emit_settings();
    }

    pub fn save_api_key(&self, key: &str) -> Result<(), String> {
        let key = key.trim();
        if key.is_empty() {
            self.secrets.delete(API_KEY_ACCOUNT)?;
        } else {
            self.secrets.save(API_KEY_ACCOUNT, key)?;
        }
        self.emit_settings();
        Ok(())
    }

    // MARK: ChatGPT connection

    async fn load_chatgpt_models(&self, token: &str) -> Result<(), InferenceError> {
        let models = self.openai.list_chatgpt_models(token).await?;
        if models.is_empty() {
            return Err(InferenceError::InvalidModel);
        }
        let mut settings = self.settings();
        if !models.iter().any(|m| m.slug == settings.chatgpt_model) {
            settings.chatgpt_model = models[0].slug.clone();
            let _ = self.save_settings(settings);
        }
        self.update_connection(|c| c.chatgpt_models = models);
        Ok(())
    }

    /// Runs a connection action with the busy flag set; returns None if one is running.
    async fn with_connection<T>(&self, message: Option<&str>, action: impl std::future::Future<Output = T>) -> Option<T> {
        {
            let mut connection = self.connection.lock().unwrap();
            if connection.busy || self.result().is_working() {
                return None;
            }
            connection.busy = true;
            connection.message = message.map(str::to_string);
        }
        self.emit_settings();
        let output = action.await;
        self.update_connection(|c| c.busy = false);
        Some(output)
    }

    fn set_message(&self, message: impl Into<Option<String>>) {
        let message = message.into();
        self.update_connection(|c| c.message = message);
    }

    pub async fn chatgpt_sign_in(&self, new_account: bool, request_consent: bool) {
        let app = self.app.clone();
        let open = move |url: &str| ui::open_url(&app, url);
        let result = self
            .with_connection(Some("브라우저에서 ChatGPT 로그인과 구독 사용 권한을 확인해 주세요."), async {
                self.chatgpt.sign_in(new_account, request_consent, open).await?;
                self.update_connection(|c| c.chatgpt_models.clear());
                if !self.chatgpt.active_permits_inference() {
                    return Ok("로그인은 완료되었지만 구독 사용 권한이 없습니다. 구독 사용 허용을 눌러 주세요.".to_string());
                }
                let token = self.chatgpt.access_token().await?;
                self.load_chatgpt_models(&token).await.map_err(|e| AuthError::OAuth(e.to_string()))?;
                let mut settings = self.settings();
                settings.billing_mode = BillingMode::ChatGpt;
                let _ = self.save_settings(settings);
                Ok::<_, AuthError>("ChatGPT 구독 사용이 연결되었습니다. 요청은 ChatGPT 구독 사용량에서 차감됩니다.".to_string())
            })
            .await;
        if let Some(result) = result {
            self.set_message(result.unwrap_or_else(|e| e.to_string()));
        }
    }

    pub fn chatgpt_cancel(&self) {
        self.chatgpt.cancel_sign_in();
    }

    pub async fn chatgpt_select(&self, client_id: &str) {
        if let Err(error) = self.chatgpt.select_profile(client_id) {
            return self.set_message(error.to_string());
        }
        self.update_connection(|c| c.chatgpt_models.clear());
        self.chatgpt_refresh_models().await;
    }

    pub async fn chatgpt_refresh_models(&self) {
        let result = self
            .with_connection(None, async {
                let token = self.chatgpt.access_token().await.map_err(|e| e.to_string())?;
                self.load_chatgpt_models(&token).await.map_err(|e| e.to_string())
            })
            .await;
        if let Some(result) = result {
            self.set_message(result.err());
        }
    }

    pub async fn chatgpt_sign_out(&self) {
        let result = self.with_connection(None, self.chatgpt.sign_out()).await;
        self.update_connection(|c| c.chatgpt_models.clear());
        match result {
            Some(Ok(true)) => self.set_message("ChatGPT 연결에서 로그아웃했습니다.".to_string()),
            Some(Ok(false)) => self.set_message("앱에서 로그아웃했습니다. 서버의 연결 해제는 확인하지 못했으니 ChatGPT 설정에서도 연결을 해제해 주세요.".to_string()),
            Some(Err(error)) => self.set_message(error.to_string()),
            None => {}
        }
    }

    // MARK: Claude Code connection

    fn claude(&self) -> ClaudeCode {
        let settings = self.settings();
        ClaudeCode { executable_path: settings.claude_path, model: settings.claude_model }
    }

    pub async fn claude_refresh_status(&self) {
        let claude = self.claude();
        let result = self.with_connection(None, claude.status()).await;
        match result {
            Some(Ok(status)) => {
                let message = (!status.logged_in).then(|| InferenceError::ClaudeNotLoggedIn.to_string());
                self.update_connection(|c| {
                    c.claude_status = Some(status);
                    c.message = message;
                });
            }
            Some(Err(error)) => self.update_connection(|c| {
                c.claude_status = None;
                c.message = Some(error.to_string());
            }),
            None => {}
        }
    }

    pub async fn claude_sign_in(&self) {
        let claude = self.claude();
        let task = tokio::spawn(async move { claude.login().await });
        *self.claude_login.lock().unwrap() = Some(task.abort_handle());
        let result = self.with_connection(Some("브라우저에서 Claude 로그인을 완료해 주세요. Claude Code가 로그인을 처리합니다."), task).await;
        *self.claude_login.lock().unwrap() = None;
        match result {
            Some(Ok(Ok(()))) => {
                self.claude_refresh_status().await;
                if self.connection.lock().unwrap().claude_status.as_ref().is_some_and(|s| s.logged_in) {
                    self.set_message("Claude 구독 사용이 연결되었습니다.".to_string());
                }
            }
            Some(Ok(Err(error))) => self.set_message(error.to_string()),
            Some(Err(_)) => self.set_message("로그인을 취소했습니다.".to_string()),
            None => {}
        }
    }

    pub fn claude_cancel(&self) {
        if let Some(handle) = self.claude_login.lock().unwrap().take() {
            handle.abort();
        }
    }
}
