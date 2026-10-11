//! IPC commands for the windows, plus tray and shortcut dispatch.

use crate::core::{Action, Core, ResultState, SettingsView};
use crate::settings::Settings;
use crate::ui;
use std::sync::Arc;
use tauri::{AppHandle, Manager, State};

type CoreState<'a> = State<'a, Arc<Core>>;

pub fn run(app: &AppHandle, action: Action) {
    app.state::<Arc<Core>>().start(action);
}

pub fn menu_action(app: &AppHandle, id: &str) {
    match id {
        "capture" => run(app, Action::Capture),
        "text" => run(app, Action::Text),
        "code" => run(app, Action::Code),
        "capture-code" => run(app, Action::CaptureCode),
        "cancel" => app.state::<Arc<Core>>().cancel(),
        "result" => ui::show_result(app),
        "settings" => ui::show_settings(app),
        "quit" => app.exit(0),
        _ => {}
    }
}

#[tauri::command]
pub fn get_result(core: CoreState) -> ResultState {
    core.result()
}

#[tauri::command]
pub fn get_settings(core: CoreState) -> SettingsView {
    core.settings_view()
}

#[tauri::command]
pub fn start(app: AppHandle, action: String) {
    if let Some(action) = Action::from_id(&action) {
        run(&app, action);
    }
}

#[tauri::command]
pub fn cancel_request(core: CoreState) {
    core.cancel();
}

#[tauri::command]
pub fn set_reasoning(core: CoreState, effort: String) -> Result<(), String> {
    core.set_reasoning(&effort)
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Permissions {
    accessibility: bool,
    screen_recording: bool,
}

/// What macOS currently grants this running app; `None` where the OS has no such switch.
#[tauri::command]
pub fn permission_status() -> Option<Permissions> {
    crate::platform::permission_status().map(|(accessibility, screen_recording)| Permissions { accessibility, screen_recording })
}

#[tauri::command]
pub fn copy_explanation(core: CoreState) {
    core.copy_explanation();
}

#[tauri::command]
pub fn copy_code(core: CoreState, id: usize) {
    core.copy_code(id);
}

#[tauri::command]
pub fn save_settings(core: CoreState, settings: Settings) -> Result<(), String> {
    core.save_settings(settings)
}

#[tauri::command]
pub fn save_api_key(core: CoreState, key: String) -> Result<(), String> {
    core.save_api_key(&key)
}

#[tauri::command]
pub async fn chatgpt_sign_in(core: CoreState<'_>, new_account: bool, request_consent: bool) -> Result<(), ()> {
    core.chatgpt_sign_in(new_account, request_consent).await;
    Ok(())
}

#[tauri::command]
pub fn chatgpt_cancel(core: CoreState) {
    core.chatgpt_cancel();
}

#[tauri::command]
pub async fn chatgpt_select(core: CoreState<'_>, client_id: String) -> Result<(), ()> {
    core.chatgpt_select(&client_id).await;
    Ok(())
}

#[tauri::command]
pub async fn chatgpt_refresh_models(core: CoreState<'_>) -> Result<(), ()> {
    core.chatgpt_refresh_models().await;
    Ok(())
}

#[tauri::command]
pub async fn chatgpt_sign_out(core: CoreState<'_>) -> Result<(), ()> {
    core.chatgpt_sign_out().await;
    Ok(())
}

#[tauri::command]
pub async fn claude_refresh_status(core: CoreState<'_>) -> Result<(), ()> {
    core.claude_refresh_status().await;
    Ok(())
}

#[tauri::command]
pub async fn claude_sign_in(core: CoreState<'_>) -> Result<(), ()> {
    core.claude_sign_in().await;
    Ok(())
}

#[tauri::command]
pub fn claude_cancel(core: CoreState) {
    core.claude_cancel();
}

#[tauri::command]
pub fn open_link(app: AppHandle, url: String) -> Result<(), String> {
    ui::open_url(&app, &url)
}

#[tauri::command]
pub fn open_privacy_settings(app: AppHandle, kind: String) -> Result<(), String> {
    let url = crate::platform::privacy_settings_url(&kind).ok_or("이 OS에는 해당 설정이 없습니다.")?;
    ui::open_url(&app, url)
}

#[tauri::command]
pub fn open_settings(app: AppHandle) {
    ui::show_settings(&app);
}

/// Runs an action from the custom menu-bar popover, then closes that popover.
#[tauri::command]
pub fn tray_action(app: AppHandle, action: String) {
    if action == "focus-settings" {
        ui::hide_tray(&app);
        let _ = ui::open_url(&app, "x-apple.systempreferences:com.apple.Focus-Settings.extension");
        return;
    }
    if matches!(action.as_str(), "capture" | "text" | "code" | "capture-code" | "cancel" | "result" | "settings" | "quit") {
        ui::hide_tray(&app);
        menu_action(&app, &action);
    }
}

#[tauri::command]
pub fn get_tray_mode() -> bool {
    crate::tray::app_menu()
}

#[tauri::command]
pub fn get_tray_symbols() -> std::collections::HashMap<&'static str, String> {
    crate::tray::symbols()
}

#[tauri::command]
pub fn hide_window(window: tauri::WebviewWindow) {
    let _ = window.hide();
}

#[tauri::command]
pub fn overlay_image() -> Option<String> {
    #[cfg(windows)]
    return crate::platform::overlay_image();
    #[cfg(not(windows))]
    None
}

#[tauri::command]
pub fn overlay_finish(rect: Option<serde_json::Value>) {
    #[cfg(windows)]
    crate::platform::finish_overlay(rect.and_then(|r| serde_json::from_value(r).ok()));
    #[cfg(not(windows))]
    let _ = rect;
}
