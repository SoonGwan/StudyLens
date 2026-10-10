//! App state and the three user workflows (capture, selected text, quick code copy).
//! Windows render snapshots of this state; every change is pushed as an event.
//!
//! Each request gets an id. Cancelling aborts its task and retires the id, so a late
//! completion can never overwrite a newer request or touch the clipboard.

use crate::auth::chatgpt::{ChatGptAuth, ProfileSummary};
use crate::auth::AuthError;
use crate::document::{self, Block};
use crate::inference::capabilities::{self, InputError};
use crate::inference::claude_code::{self, ClaudeCode, ClaudeStatus};
use crate::inference::openai::{ChatGptModel, Credential, CredentialKind, OpenAIClient, OpenAIProvider};
use crate::inference::{InferenceError, InferenceProvider, Progress};
use crate::platform::{self, CaptureError, SelectionError, SelectionReader};
use crate::progress::{RequestProgress, Stage};
use crate::quick_code::{self, QuickCodeError};
use crate::secrets::SecretStore;
use crate::settings::{self, BillingMode, Settings};
use crate::{hotkeys, tray, ui};
use base64::Engine;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Capture,
    Text,
    Code,
}

/// Points the result window at the fix for an error.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Hint {
    Accessibility,
    ScreenRecording,
    /// Input or permission problem, explicitly not a login or usage problem.
    Input,
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
    pub progress: Option<RequestProgress>,
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
pub struct ReasoningView {
    pub choices: Vec<&'static str>,
    pub selected: String,
    /// What is actually sent: `None` means the `reasoning` field is omitted.
    pub sent: Option<String>,
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
    pub reasoning: ReasoningView,
    pub image_supported: bool,
    pub platform: &'static str,
    pub working: bool,
}

/// How a workflow ended other than success.
pub enum Stop {
    Fail(Failure),
    Cancelled,
}

pub struct Failure {
    message: String,
    hint: Option<Hint>,
}

impl Failure {
    fn new(message: impl ToString, hint: Option<Hint>) -> Self {
        Self { message: message.to_string(), hint }
    }
}

impl<T: Into<Failure>> From<T> for Stop {
    fn from(value: T) -> Self {
        Stop::Fail(value.into())
    }
}

impl From<SelectionError> for Failure {
    fn from(error: SelectionError) -> Self {
        let hint = if error == SelectionError::PermissionDenied && cfg!(target_os = "macos") { Hint::Accessibility } else { Hint::Input };
        Failure::new(error, Some(hint))
    }
}

impl From<CaptureError> for Failure {
    fn from(error: CaptureError) -> Self {
        let hint = if error == CaptureError::PermissionDenied { Hint::ScreenRecording } else { Hint::Input };
        Failure::new(error, Some(hint))
    }
}

impl From<InputError> for Failure {
    fn from(error: InputError) -> Self {
        Failure::new(error, Some(Hint::Input))
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

fn data_url(png: &[u8]) -> String {
    format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(png))
}

fn capture_stop(error: CaptureError) -> Stop {
    if error == CaptureError::Cancelled { Stop::Cancelled } else { Stop::Fail(error.into()) }
}

/// Everything a request needs, fixed when it starts so later settings edits don't leak in.
#[derive(Clone)]
struct Options {
    mode: BillingMode,
    model: String,
    effort: String,
    language: String,
    attach_image: bool,
    additional_instructions: String,
    claude_path: String,
}

struct Active {
    id: u64,
    task: Option<tokio::task::AbortHandle>,
}

pub struct Core {
    pub app: AppHandle,
    me: Weak<Core>,
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
    active: Mutex<Option<Active>>,
    next_id: AtomicU64,
}

impl Core {
    pub fn new(app: AppHandle, config_dir: PathBuf, secrets: Arc<dyn SecretStore>) -> Arc<Self> {
        let settings_path = settings::path(&config_dir);
        let settings = settings::load(&settings_path);
        let chatgpt = ChatGptAuth::new(secrets.clone(), settings.host_id.clone());
        Arc::new_cyclic(|me| Self {
            app,
            me: me.clone(),
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
            active: Mutex::new(None),
            next_id: AtomicU64::new(1),
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
        let settings = self.settings();
        let (chatgpt_profiles, active_client_id) = self.chatgpt.profiles();
        let model = settings.billing_mode.model(&settings);
        let selected = capabilities::preference(&settings, settings.billing_mode, &model);
        let claude = settings.billing_mode == BillingMode::ClaudeCode;
        SettingsView {
            has_api_key: self.secrets.load(API_KEY_ACCOUNT).ok().flatten().is_some_and(|k| !k.is_empty()),
            chatgpt_profiles,
            active_client_id,
            connection: self.connection.lock().unwrap().clone(),
            shortcut_errors: self.shortcut_errors.lock().unwrap().clone(),
            code_languages: settings::CODE_LANGUAGES.to_vec(),
            claude_models: claude_code::MODELS.to_vec(),
            reasoning: ReasoningView {
                choices: if claude { vec![capabilities::MODEL_DEFAULT] } else { capabilities::reasoning_choices(&model) },
                sent: if claude { None } else { capabilities::validated_effort(&selected, &model) },
                selected,
            },
            image_supported: !claude && capabilities::supports_image(&model),
            platform: if cfg!(target_os = "macos") { "macos" } else { "windows" },
            working: self.result().is_working(),
            settings,
        }
    }

    fn publish(&self, snapshot: &ResultState) {
        let _ = self.app.emit("result", snapshot);
        tray::update(&self.app, snapshot, &self.settings());
        self.emit_settings();
    }

    fn update_result(&self, change: impl FnOnce(&mut ResultState)) {
        let snapshot = {
            let mut state = self.result.lock().unwrap();
            change(&mut state);
            state.clone()
        };
        self.publish(&snapshot);
    }

    fn is_current(&self, id: u64) -> bool {
        self.active.lock().unwrap().as_ref().is_some_and(|a| a.id == id)
    }

    /// Applies a change only while `id` is still the active request.
    fn update_for(&self, id: u64, change: impl FnOnce(&mut ResultState)) -> Result<(), Stop> {
        let snapshot = {
            let active = self.active.lock().unwrap();
            if !active.as_ref().is_some_and(|a| a.id == id) {
                return Err(Stop::Cancelled);
            }
            let mut state = self.result.lock().unwrap();
            change(&mut state);
            state.clone()
        };
        self.publish(&snapshot);
        Ok(())
    }

    fn progress_for(&self, id: u64, change: impl FnOnce(&mut RequestProgress)) -> Result<(), Stop> {
        self.update_for(id, |s| {
            if let Some(progress) = s.progress.as_mut() {
                change(progress);
            }
        })
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

    fn options(&self) -> Options {
        let settings = self.settings();
        let mode = settings.billing_mode;
        let model = mode.model(&settings);
        Options {
            effort: capabilities::preference(&settings, mode, &model),
            attach_image: settings.attach_image && mode != BillingMode::ClaudeCode,
            additional_instructions: settings.additional_instructions.clone(),
            language: settings.code_language.clone(),
            claude_path: settings.claude_path.clone(),
            model,
            mode,
        }
    }

    // MARK: request lifecycle

    /// Starts a workflow unless one is already running or a connection change is in progress.
    pub fn start(&self, action: Action) {
        let Some(core) = self.me.upgrade() else { return };
        let options = self.options();
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let silent = action == Action::Code;
        {
            let mut active = self.active.lock().unwrap();
            let mut state = self.result.lock().unwrap();
            if active.is_some() || state.is_working() || self.connection_busy() {
                return;
            }
            *active = Some(Active { id, task: None });
            let stage = if action == Action::Capture { Stage::SelectingImage } else { Stage::ReadingSelection };
            let effort = if options.mode == BillingMode::ClaudeCode { None } else { capabilities::validated_effort(&options.effort, &options.model) };
            *state = ResultState {
                status: Status::Selecting,
                quick_copy_message: silent.then(|| "선택한 텍스트 읽는 중…".to_string()),
                billing_label: options.mode.title().into(),
                progress: Some(RequestProgress::new(stage, &options.model, options.mode.title(), effort.as_deref())),
                ..Default::default()
            };
        }
        self.publish(&self.result());
        if silent {
            ui::hide_result(&self.app);
        }
        let task = tauri::async_runtime::spawn(async move {
            let outcome = match action {
                Action::Capture => core.capture_flow(id, &options).await,
                Action::Text => core.text_flow(id, &options).await,
                Action::Code => core.code_flow(id, &options).await,
            };
            core.conclude(id, outcome, silent, options.mode);
        });
        if let Some(active) = self.active.lock().unwrap().as_mut().filter(|a| a.id == id) {
            active.task = Some(task.inner().abort_handle());
        }
    }

    fn conclude(&self, id: u64, outcome: Result<(), Stop>, silent: bool, mode: BillingMode) {
        match outcome {
            Ok(()) => {
                let _ = self.update_for(id, |s| {
                    if let Some(progress) = s.progress.as_mut() {
                        if mode == BillingMode::ClaudeCode {
                            progress.record(Progress::FirstText);
                        }
                        progress.record(Progress::Completed);
                        progress.finish(Stage::Completed);
                    }
                    s.status = Status::Ready;
                });
            }
            Err(Stop::Cancelled) => {
                if self.is_current(id) {
                    self.cancel();
                }
            }
            Err(Stop::Fail(failure)) => {
                let applied = self.update_for(id, |s| {
                    if let Some(progress) = s.progress.as_mut() {
                        progress.finish(Stage::Failed);
                    }
                    s.status = Status::Failed;
                    s.error_message = Some(failure.message);
                    s.hint = failure.hint;
                    if silent {
                        s.quick_copy_message = Some("복사하지 못했습니다 · 메뉴에서 결과 확인".into());
                    }
                });
                if applied.is_ok() && !silent {
                    ui::show_result(&self.app);
                }
            }
        }
        let mut active = self.active.lock().unwrap();
        if active.as_ref().is_some_and(|a| a.id == id) {
            *active = None;
        }
    }

    /// Stops the running request; its late results are discarded and the clipboard is untouched.
    pub fn cancel(&self) {
        let Some(active) = self.active.lock().unwrap().take() else { return };
        if let Some(task) = active.task {
            task.abort();
        }
        self.update_result(|s| {
            if let Some(progress) = s.progress.as_mut() {
                progress.finish(Stage::Cancelled);
            }
            s.status = Status::Idle;
            s.explanation.clear();
            s.blocks.clear();
            s.copied_code_id = None;
            s.error_message = None;
            s.hint = None;
            s.quick_copy_message = Some("요청을 취소했습니다 · 기존 클립보드는 유지했습니다.".into());
        });
    }

    // MARK: workflows

    async fn capture_flow(&self, id: u64, options: &Options) -> Result<(), Stop> {
        let png = platform::capture_region(&self.app, true).await.map_err(capture_stop)?;
        let image = data_url(&png);
        self.update_for(id, |s| {
            s.captured_image = Some(image);
            if let Some(p) = s.progress.as_mut() {
                p.prepare_connection();
            }
        })?;
        let provider = self.provider(id, options, None).await?;
        self.begin_inference(id, false)?;
        let answer = provider.explain_image(&png).await.map_err(|e| self.inference_failure(e))?;
        self.set_explanation(id, &answer)
    }

    async fn text_flow(&self, id: u64, options: &Options) -> Result<(), Stop> {
        // Read the selection before anything else can move focus.
        let text = self.selection.read(true).await?;
        self.update_for(id, |s| {
            s.selected_text = text.clone();
            if let Some(p) = s.progress.as_mut() {
                p.finish_selection();
            }
        })?;
        capabilities::validate_text(&text, &options.additional_instructions)?;
        let image = self.optional_image(id, options, false).await?;
        self.progress_for(id, RequestProgress::prepare_connection)?;
        let provider = self.provider(id, options, image).await?;
        self.begin_inference(id, false)?;
        let answer = provider.explain_text(&text).await.map_err(|e| self.inference_failure(e))?;
        self.set_explanation(id, &answer)
    }

    /// Never opens the result window, on success or failure: progress shows in the tray.
    async fn code_flow(&self, id: u64, options: &Options) -> Result<(), Stop> {
        let text = self.selection.read(false).await?;
        self.update_for(id, |s| {
            s.selected_text = text.clone();
            s.status = Status::Analyzing;
            s.quick_copy_message = Some("코드 작성 중… 완료되면 클립보드에 복사합니다.".into());
            if let Some(p) = s.progress.as_mut() {
                p.finish_selection();
            }
        })?;
        capabilities::validate_text(&text, &options.additional_instructions)?;
        let image = self.optional_image(id, options, true).await?;
        self.progress_for(id, RequestProgress::prepare_connection)?;
        let provider = self.provider(id, options, image).await?;
        self.begin_inference(id, true)?;
        let response = provider.generate_code(&text, &options.language).await.map_err(|e| self.inference_failure(e))?;
        let shown = quick_code::normalize_complete_java_source(&response);
        self.set_explanation(id, &shown)?;
        self.progress_for(id, |p| p.set_stage(Stage::Copying))?;
        let extracted = quick_code::extract(&response)?;
        // Last check right before touching the clipboard.
        if !self.is_current(id) {
            return Err(Stop::Cancelled);
        }
        if self.app.clipboard().write_text(extracted.block.text.clone()).is_err() {
            return Err(Failure::new("코드를 클립보드에 저장하지 못했습니다.", None).into());
        }
        let paste = if cfg!(target_os = "macos") { "⌘V" } else { "Ctrl+V" };
        self.update_for(id, |s| {
            s.copied_code_id = Some(extracted.block.id);
            s.quick_copy_message = Some(format!("코드 복사 완료 · {paste}로 붙여넣기"));
        })
    }

    async fn optional_image(&self, id: u64, options: &Options, silent: bool) -> Result<Option<Vec<u8>>, Stop> {
        if !options.attach_image {
            return Ok(None);
        }
        if !capabilities::supports_image(&options.model) {
            return Err(InputError::UnsupportedImageModel.into());
        }
        self.update_for(id, |s| {
            if silent {
                s.quick_copy_message = Some("첨부할 그림 영역을 직접 선택하세요 · Esc로 취소".into());
            }
            if let Some(p) = s.progress.as_mut() {
                p.set_stage(Stage::SelectingImage);
            }
        })?;
        // The silent flow never pops a permission dialog; it reports the missing permission.
        let png = platform::capture_region(&self.app, !silent).await.map_err(capture_stop)?;
        capabilities::validate_image(&png, &options.model)?;
        let image = data_url(&png);
        self.update_for(id, |s| s.captured_image = Some(image))?;
        Ok(Some(png))
    }

    fn begin_inference(&self, id: u64, silent: bool) -> Result<(), Stop> {
        self.update_for(id, |s| {
            s.status = Status::Analyzing;
            if let Some(p) = s.progress.as_mut() {
                p.wait_for_response();
            }
        })?;
        if !silent {
            ui::show_result(&self.app);
        }
        Ok(())
    }

    fn set_explanation(&self, id: u64, text: &str) -> Result<(), Stop> {
        let blocks = document::parse(text);
        self.update_for(id, |s| {
            s.explanation = text.to_string();
            s.blocks = blocks;
        })
    }

    fn usage_hint(&self) -> Option<Hint> {
        match self.settings().billing_mode {
            BillingMode::ChatGpt => Some(Hint::ChatGptUsage),
            BillingMode::ClaudeCode => Some(Hint::ClaudeUsage),
            BillingMode::ApiKey => None,
        }
    }

    fn inference_failure(&self, error: InferenceError) -> Stop {
        let hint = match error {
            InferenceError::Input(_) => Some(Hint::Input),
            InferenceError::ClaudeNotInstalled | InferenceError::ClaudeNotLoggedIn | InferenceError::InvalidModel => Some(Hint::Settings),
            InferenceError::TimedOut | InferenceError::Network(_) => None,
            _ => self.usage_hint(),
        };
        Stop::Fail(Failure::new(error, hint))
    }

    async fn provider(&self, id: u64, options: &Options, image: Option<Vec<u8>>) -> Result<Box<dyn InferenceProvider>, Stop> {
        let provider: Box<dyn InferenceProvider> = match options.mode {
            BillingMode::ClaudeCode => {
                let claude = ClaudeCode {
                    executable_path: options.claude_path.clone(),
                    model: options.model.clone(),
                    additional_instructions: options.additional_instructions.clone(),
                };
                claude.check_installed().await.map_err(|e| self.inference_failure(e))?;
                Box::new(claude)
            }
            BillingMode::ApiKey => {
                let key = self.secrets.load(API_KEY_ACCOUNT).map_err(|e| Failure::new(e, None))?.unwrap_or_default();
                if key.is_empty() {
                    return Err(Failure::new("OpenAI API 키가 저장되지 않았습니다. 설정에서 키를 저장해 주세요.", Some(Hint::Settings)).into());
                }
                self.openai_provider(id, options, Credential { token: key, kind: CredentialKind::ApiKey }, image)
            }
            BillingMode::ChatGpt => {
                let token = self.chatgpt.access_token().await?;
                if self.connection.lock().unwrap().chatgpt_models.is_empty() {
                    self.load_chatgpt_models(&token).await.map_err(|e| self.inference_failure(e))?;
                }
                if !self.connection.lock().unwrap().chatgpt_models.iter().any(|m| m.slug == options.model) {
                    return Err(self.inference_failure(InferenceError::InvalidModel));
                }
                self.openai_provider(id, options, Credential { token, kind: CredentialKind::ChatGpt }, image)
            }
        };
        if !self.is_current(id) {
            return Err(Stop::Cancelled);
        }
        Ok(provider)
    }

    fn openai_provider(&self, id: u64, options: &Options, credential: Credential, image: Option<Vec<u8>>) -> Box<dyn InferenceProvider> {
        let me = self.me.clone();
        let mut provider = OpenAIProvider::new(self.openai.clone(), credential, options.model.clone());
        provider.effort = options.effort.clone();
        provider.image = image;
        provider.additional_instructions = options.additional_instructions.clone();
        provider.progress = Some(Arc::new(move |event| {
            if let Some(core) = me.upgrade() {
                let _ = core.progress_for(id, |p| p.record(event));
            }
        }));
        Box::new(provider)
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
        let blocks = document::parse(&text);
        self.update_result(|s| {
            s.explanation = text;
            s.blocks = blocks;
            s.status = Status::Ready;
        });
    }

    /// Stores the reasoning effort for the current mode and model.
    pub fn set_reasoning(&self, effort: &str) -> Result<(), String> {
        if self.result().is_working() {
            return Err("요청 중에는 바꿀 수 없습니다.".into());
        }
        let mut settings = self.settings();
        let model = settings.billing_mode.model(&settings);
        let value = if capabilities::reasoning_choices(&model).contains(&effort) { effort } else { capabilities::MODEL_DEFAULT };
        settings.reasoning.insert(capabilities::preference_key(settings.billing_mode, &model), value.to_string());
        self.save_settings(settings)
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
        ClaudeCode { executable_path: settings.claude_path, model: settings.claude_model, ..Default::default() }
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
