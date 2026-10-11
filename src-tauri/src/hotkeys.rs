//! Global shortcuts. Each must include Command/Ctrl, Option/Alt or Control.

use crate::core::Action;
use crate::settings::Shortcuts;
use tauri::{AppHandle, Manager};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};

pub fn plugin() -> tauri::plugin::TauriPlugin<tauri::Wry> {
    tauri_plugin_global_shortcut::Builder::new()
        .with_handler(|app, shortcut, event| {
            if event.state() != ShortcutState::Pressed {
                return;
            }
            let Some(core) = app.try_state::<std::sync::Arc<crate::core::Core>>() else { return };
            let settings = core.settings();
            let action = [
                (&settings.shortcuts.capture, Action::Capture),
                (&settings.shortcuts.text, Action::Text),
                (&settings.shortcuts.code, Action::Code),
                (&settings.shortcuts.capture_code, Action::CaptureCode),
            ]
            .into_iter()
            .find(|(text, _)| text.parse::<Shortcut>().is_ok_and(|s| &s == shortcut))
            .map(|(_, action)| action);
            if let Some(action) = action {
                crate::commands::run(app, action);
            }
        })
        .build()
}

/// Registers all shortcuts, returning a readable message for each one that failed.
pub fn register(app: &AppHandle, shortcuts: &Shortcuts) -> Vec<String> {
    let manager = app.global_shortcut();
    let _ = manager.unregister_all();
    let mut errors = Vec::new();
    for (name, text) in [("영역 캡처", &shortcuts.capture), ("선택 텍스트", &shortcuts.text), ("코드 바로 복사", &shortcuts.code), ("문제 캡처 → 코드 복사", &shortcuts.capture_code)] {
        let result = text.parse::<Shortcut>().map_err(|e| e.to_string()).and_then(|shortcut| manager.register(shortcut).map_err(|e| e.to_string()));
        if let Err(error) = result {
            errors.push(format!("{name} 단축키({text})를 등록하지 못했습니다. 다른 앱이 사용 중일 수 있습니다. ({error})"));
        }
    }
    errors
}
