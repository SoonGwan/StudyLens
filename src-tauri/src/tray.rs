//! System-symbol menu-bar icon and a Focus-style popover. Option reveals app actions.

use crate::core::{ResultState, Status};
use crate::settings::Settings;
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager};
use std::sync::atomic::{AtomicBool, Ordering};

const TRAY_ID: &str = "studylens";
static APP_MENU: AtomicBool = AtomicBool::new(false);
static OPTION_AT_PRESS: AtomicBool = AtomicBool::new(false);

pub fn app_menu() -> bool {
    APP_MENU.load(Ordering::Relaxed)
}

pub fn create(app: &AppHandle) -> tauri::Result<TrayIcon> {
    let state = ResultState::default();
    TrayIconBuilder::with_id(TRAY_ID)
        .icon(moon())
        .icon_as_template(true)
        .tooltip("StudyLens")
        .menu(&menu(app, &state, &Settings::default())?)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| crate::commands::menu_action(app, event.id().as_ref()))
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { rect, button: MouseButton::Left, button_state, .. } = event {
                match button_state {
                    MouseButtonState::Down => OPTION_AT_PRESS.store(option_pressed(), Ordering::Relaxed),
                    MouseButtonState::Up => {
                        let mode = app_menu_for_click(OPTION_AT_PRESS.load(Ordering::Relaxed), option_pressed(), cfg!(target_os = "macos"));
                        APP_MENU.store(mode, Ordering::Relaxed);
                        let app = tray.app_handle();
                        let _ = app.emit("tray-mode", mode);
                        crate::ui::toggle_tray(app, rect);
                    }
                }
            }
        })
        .build(app)
}

pub fn update(app: &AppHandle, state: &ResultState, settings: &Settings) {
    let Some(tray) = app.tray_by_id(TRAY_ID) else { return };
    let _ = tray.set_icon(Some(moon()));
    // Match the system Focus icon in light and dark menu bars.
    let _ = tray.set_icon_as_template(true);
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

/// macOS uses the native moon.fill symbol as an 18pt template image at 2x.
pub fn moon() -> Image<'static> {
    #[cfg(target_os = "macos")]
    return Image::from_bytes(include_bytes!(concat!(env!("OUT_DIR"), "/tray-moon.png")))
        .expect("build script rendered a valid system symbol PNG");
    #[cfg(not(target_os = "macos"))]
    fallback_moon()
}

#[cfg(any(not(target_os = "macos"), test))]
fn fallback_moon() -> Image<'static> {
    const SIZE: u32 = 36;
    let center = (16.5_f32, 18.0_f32);
    let cutout = (21.5_f32, 13.3_f32);
    let radius = 13.0_f32;
    let cutout_radius = 12.2_f32;
    let mut rgba = Vec::with_capacity((SIZE * SIZE * 4) as usize);
    for y in 0..SIZE {
        for x in 0..SIZE {
            let px = x as f32 + 0.5;
            let py = y as f32 + 0.5;
            let outer = (radius + 0.5 - ((px - center.0).powi(2) + (py - center.1).powi(2)).sqrt()).clamp(0.0, 1.0);
            let hole = (cutout_radius + 0.5 - ((px - cutout.0).powi(2) + (py - cutout.1).powi(2)).sqrt()).clamp(0.0, 1.0);
            let alpha = outer * (1.0 - hole);
            rgba.extend_from_slice(&[0, 0, 0, (alpha * 255.0) as u8]);
        }
    }
    Image::new_owned(rgba, SIZE, SIZE)
}

#[cfg(target_os = "macos")]
fn option_pressed() -> bool {
    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGEventSourceFlagsState(state_id: i32) -> u64;
    }
    const ALTERNATE: u64 = 1 << 19;
    // Combined-session state reflects the modifier held during the menu-bar click.
    unsafe { CGEventSourceFlagsState(0) & ALTERNATE != 0 }
}

#[cfg(not(target_os = "macos"))]
fn option_pressed() -> bool {
    false
}

fn app_menu_for_click(option_at_press: bool, option_at_release: bool, macos: bool) -> bool {
    option_at_press || option_at_release || !macos
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn option_click_reveals_app_actions() {
        assert!(!app_menu_for_click(false, false, true));
        assert!(app_menu_for_click(true, false, true));
        assert!(app_menu_for_click(false, true, true));
        assert!(app_menu_for_click(true, true, true));
        assert!(app_menu_for_click(false, false, false), "Windows opens app actions normally");
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn native_symbol_is_visible_with_transparent_padding() {
        let image = moon();
        assert_eq!((image.width(), image.height()), (36, 36));
        let visible = image.rgba().chunks_exact(4).filter(|p| p[3] > 20).count();
        assert!(visible > 200 && visible < 900, "symbol must be visible, not blank or a filled square");
        assert_eq!(image.rgba()[3], 0, "template padding is transparent");
    }

    #[test]
    fn moon_is_a_template_crescent() {
        let image = fallback_moon();
        let alpha = |x: usize, y: usize| image.rgba()[(y * 36 + x) * 4 + 3];
        assert!(alpha(9, 21) > 200, "lower-left body is opaque");
        assert_eq!(alpha(21, 13), 0, "upper-right cutout is transparent");
        assert_eq!(alpha(0, 0), 0, "corners are transparent");
        assert!(image.rgba().chunks_exact(4).all(|pixel| pixel[..3] == [0, 0, 0]));
    }
}
