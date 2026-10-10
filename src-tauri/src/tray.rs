//! Menu bar / system tray: a small status dot and a native menu.

use crate::core::{ResultState, Status};
use crate::settings::Settings;
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{TrayIcon, TrayIconBuilder};
use tauri::{AppHandle, Manager};

const TRAY_ID: &str = "studylens";

pub fn create(app: &AppHandle) -> tauri::Result<TrayIcon> {
    let state = ResultState::default();
    TrayIconBuilder::with_id(TRAY_ID)
        .icon(dot(state.status))
        .icon_as_template(true)
        .tooltip("StudyLens")
        .menu(&menu(app, &state, &Settings::default())?)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| crate::commands::menu_action(app, event.id().as_ref()))
        .build(app)
}

pub fn update(app: &AppHandle, state: &ResultState, settings: &Settings) {
    let Some(tray) = app.tray_by_id(TRAY_ID) else { return };
    let _ = tray.set_icon(Some(dot(state.status)));
    // Idle follows the menu bar's light/dark appearance; states keep their color.
    let _ = tray.set_icon_as_template(state.status == Status::Idle);
    let _ = tray.set_tooltip(Some(format!("StudyLens · {}", state.quick_copy_message.clone().unwrap_or_else(|| title(state.status).into()))));
    if let Ok(menu) = menu(app, state, settings) {
        let _ = tray.set_menu(Some(menu));
    }
}

fn title(status: Status) -> &'static str {
    match status {
        Status::Idle => "대기 중",
        Status::Selecting => "영역·텍스트 선택 중",
        Status::Analyzing => "설명 작성 중",
        Status::Ready => "결과 준비됨",
        Status::Failed => "확인 필요",
    }
}

fn menu(app: &AppHandle, state: &ResultState, settings: &Settings) -> tauri::Result<Menu<tauri::Wry>> {
    let working = state.is_working();
    let headline = state.quick_copy_message.clone().unwrap_or_else(|| title(state.status).into());
    let shortcuts = &settings.shortcuts;
    let has_result = !working && (state.status == Status::Ready || state.status == Status::Failed);
    let items: Vec<Box<dyn tauri::menu::IsMenuItem<tauri::Wry>>> = vec![
        Box::new(MenuItem::with_id(app, "status", format!("StudyLens · {headline}"), false, None::<&str>)?),
        Box::new(MenuItem::with_id(app, "mode", settings.billing_mode.title(), false, None::<&str>)?),
        Box::new(PredefinedMenuItem::separator(app)?),
        Box::new(MenuItem::with_id(app, "capture", "영역 캡처해서 설명 받기", !working, Some(shortcuts.capture.as_str()))?),
        Box::new(MenuItem::with_id(app, "text", "선택한 텍스트 설명 받기", !working, Some(shortcuts.text.as_str()))?),
        Box::new(MenuItem::with_id(app, "code", "선택한 문제 → 코드 바로 복사", !working, Some(shortcuts.code.as_str()))?),
        Box::new(MenuItem::with_id(app, "cancel", "현재 요청 취소", working, None::<&str>)?),
        Box::new(PredefinedMenuItem::separator(app)?),
        Box::new(MenuItem::with_id(app, "result", "결과 보기", has_result, None::<&str>)?),
        Box::new(MenuItem::with_id(app, "settings", "설정…", true, Some("CommandOrControl+,"))?),
        Box::new(PredefinedMenuItem::separator(app)?),
        Box::new(MenuItem::with_id(app, "quit", "StudyLens 종료", true, Some("CommandOrControl+Q"))?),
    ];
    let refs: Vec<&dyn tauri::menu::IsMenuItem<tauri::Wry>> = items.iter().map(|i| i.as_ref()).collect();
    Menu::with_items(app.app_handle(), &refs)
}

/// A 9pt dot drawn at 2x: black (template) when idle, colored while busy or done.
pub fn dot(status: Status) -> Image<'static> {
    const SIZE: u32 = 36;
    let (r, g, b) = match status {
        Status::Idle => (0, 0, 0),
        Status::Selecting | Status::Analyzing => (255, 149, 0),
        Status::Ready => (52, 199, 89),
        Status::Failed => (255, 59, 48),
    };
    let center = SIZE as f32 / 2.0;
    let radius = 8.5_f32;
    let mut rgba = Vec::with_capacity((SIZE * SIZE * 4) as usize);
    for y in 0..SIZE {
        for x in 0..SIZE {
            let distance = ((x as f32 + 0.5 - center).powi(2) + (y as f32 + 0.5 - center).powi(2)).sqrt();
            let alpha = (radius + 0.5 - distance).clamp(0.0, 1.0);
            rgba.extend_from_slice(&[r, g, b, (alpha * 255.0) as u8]);
        }
    }
    Image::new_owned(rgba, SIZE, SIZE)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dots_carry_their_status_color() {
        let center = |status| {
            let image = dot(status);
            let i = ((18 * 36 + 18) * 4) as usize;
            image.rgba()[i..i + 4].to_vec()
        };
        assert_eq!(center(Status::Ready), [52, 199, 89, 255]);
        assert_eq!(center(Status::Failed)[0], 255);
        assert_eq!(center(Status::Idle)[3], 255);
        assert_eq!(dot(Status::Idle).rgba()[3], 0, "corners are transparent");
    }
}
