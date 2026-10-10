//! Result and settings windows. Both are created lazily, hidden instead of closed, and
//! never show in the Dock or taskbar on their own.

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};
use tauri_plugin_opener::OpenerExt;

pub fn show_result(app: &AppHandle) {
    present(app, "result", "result.html", "StudyLens", (640.0, 620.0), (460.0, 360.0));
}

pub fn show_settings(app: &AppHandle) {
    present(app, "settings", "settings.html", "StudyLens 설정", (560.0, 680.0), (480.0, 480.0));
}

pub fn hide_result(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("result") {
        let _ = window.hide();
    }
}

fn present(app: &AppHandle, label: &str, page: &str, title: &str, size: (f64, f64), min: (f64, f64)) {
    let window = match app.get_webview_window(label) {
        Some(window) => window,
        None => match build(app, label, page, title, size, min) {
            Ok(window) => window,
            Err(error) => return eprintln!("window {label}: {error}"),
        },
    };
    let _ = window.unminimize();
    let _ = window.show();
    let _ = window.set_focus();
}

fn build(app: &AppHandle, label: &str, page: &str, title: &str, size: (f64, f64), min: (f64, f64)) -> tauri::Result<WebviewWindow> {
    let builder = WebviewWindowBuilder::new(app, label, WebviewUrl::App(page.into()))
        .title(title)
        .inner_size(size.0, size.1)
        .min_inner_size(min.0, min.1)
        .center()
        .visible(false);
    #[cfg(target_os = "macos")]
    let builder = builder
        .title_bar_style(tauri::TitleBarStyle::Overlay)
        .hidden_title(true)
        .transparent(true)
        .effects(
            tauri::window::EffectsBuilder::new()
                .effect(tauri::window::Effect::UnderWindowBackground)
                .state(tauri::window::EffectState::FollowsWindowActiveState)
                .build(),
        );
    #[cfg(windows)]
    let builder = builder.effects(tauri::window::EffectsBuilder::new().effect(tauri::window::Effect::Mica).build());
    let window = builder.build()?;
    let handle = window.clone();
    window.on_window_event(move |event| {
        if let tauri::WindowEvent::CloseRequested { api, .. } = event {
            api.prevent_close();
            let _ = handle.hide();
        }
    });
    Ok(window)
}

/// Opens only https links and the OS privacy settings panes.
pub fn open_url(app: &AppHandle, url: &str) -> Result<(), String> {
    let allowed = url.starts_with("https://") || url.starts_with("x-apple.systempreferences:");
    if !allowed {
        return Err("허용되지 않은 주소입니다.".into());
    }
    app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
}
