mod logging;
mod shell;
mod sidecar;
mod terminal;

use std::sync::Arc;

use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, RunEvent, State, WindowEvent};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};

use logging::Logger;
use sidecar::{SidecarHost, SidecarState};

const HOTKEY: &str = "ctrl+alt+space";

#[tauri::command]
fn sidecar_info(host: State<'_, SidecarHost>) -> SidecarState {
    host.state()
}

#[tauri::command]
fn set_mode(app: AppHandle, mode: String, focus: bool) -> Result<(), String> {
    shell::apply(&app, &mode, focus)
}

#[tauri::command]
fn quit_app(app: AppHandle) {
    app.state::<SidecarHost>().kill();
    app.exit(0);
}

fn open_panel(app: &AppHandle) {
    let _ = app.emit("shell://open", ());
}

pub fn run() {
    let app = tauri::Builder::default()
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    if event.state() == ShortcutState::Pressed {
                        let _ = app.emit("shell://toggle", ());
                    }
                })
                .build(),
        )
        .manage(SidecarHost::default())
        .manage(terminal::TerminalHost::default())
        .invoke_handler(tauri::generate_handler![
            sidecar_info,
            set_mode,
            quit_app,
            terminal::terminal_spawn,
            terminal::terminal_write,
            terminal::terminal_resize,
            terminal::terminal_kill,
            terminal::terminal_shells,
            terminal::terminal_home,
            terminal::terminal_list_dir,
            terminal::terminal_executables,
            terminal::terminal_git_status,
            terminal::terminal_read_history,
        ])
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.emit("shell://close", ());
            }
        })
        .setup(|app| {
            let handle = app.handle().clone();
            let log_dir = app.path().local_data_dir()?.join("wisp").join("logs");
            let log = Arc::new(Logger::open(&log_dir)?);
            log.line("wisp started");

            if let Err(e) = app.global_shortcut().register(HOTKEY) {
                log.line(&format!("hotkey {HOTKEY} not registered: {e}"));
            }

            let open = MenuItem::with_id(app, "open", "Abrir", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Sair", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &quit])?;
            TrayIconBuilder::new()
                .icon(Image::from_bytes(include_bytes!("../icons/icon.png"))?)
                .tooltip("Wisp")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "open" => open_panel(app),
                    "quit" => {
                        app.state::<SidecarHost>().kill();
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        open_panel(tray.app_handle());
                    }
                })
                .build(app)?;

            shell::apply(&handle, "pill", false)?;
            sidecar::start(handle, log);
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building the Wisp app");

    app.run(|app, event| {
        if let RunEvent::Exit = event {
            app.state::<SidecarHost>().kill();
            app.state::<terminal::TerminalHost>().kill_all();
        }
    });
}
