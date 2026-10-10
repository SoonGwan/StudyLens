mod auth;
mod commands;
mod core;
mod document;
mod hotkeys;
mod inference;
mod platform;
mod progress;
mod quick_code;
mod secrets;
mod settings;
mod tray;
mod ui;

use std::sync::Arc;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // A second launch just opens settings in the running instance.
        .plugin(tauri_plugin_single_instance::init(|app, _, _| ui::show_settings(app)))
        .plugin(hotkeys::plugin())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            commands::get_result,
            commands::get_settings,
            commands::start,
            commands::cancel_request,
            commands::set_reasoning,
            commands::permission_status,
            commands::copy_explanation,
            commands::copy_code,
            commands::save_settings,
            commands::save_api_key,
            commands::chatgpt_sign_in,
            commands::chatgpt_cancel,
            commands::chatgpt_select,
            commands::chatgpt_refresh_models,
            commands::chatgpt_sign_out,
            commands::claude_refresh_status,
            commands::claude_sign_in,
            commands::claude_cancel,
            commands::open_link,
            commands::open_privacy_settings,
            commands::open_settings,
            commands::hide_window,
            commands::overlay_image,
            commands::overlay_finish,
        ])
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let config_dir = app.path().app_config_dir()?;
            let core = core::Core::new(app.handle().clone(), config_dir, Arc::new(secrets::Keyring));
            app.manage(core.clone());
            tray::create(app.handle())?;
            core.register_shortcuts();
            tray::update(app.handle(), &core.result(), &core.settings());

            let args: Vec<String> = std::env::args().collect();
            // `--result-file <path>` shows a saved answer without a new AI request.
            if let Some(path) = args.iter().position(|a| a == "--result-file").and_then(|i| args.get(i + 1)) {
                if let Ok(text) = std::fs::read_to_string(path) {
                    core.restore_explanation(text);
                    ui::show_result(app.handle());
                }
            }
            if args.iter().any(|a| a == "--settings") || !core.settings().onboarded {
                ui::show_settings(app.handle());
            }
            let warm = core.clone();
            tauri::async_runtime::spawn(async move { warm.selection.warm_up().await });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to build StudyLens")
        .run(|_, event| {
            // Closing every window keeps the menu bar app running.
            if let tauri::RunEvent::ExitRequested { api, code, .. } = event {
                if code.is_none() {
                    api.prevent_exit();
                }
            }
        });
}
