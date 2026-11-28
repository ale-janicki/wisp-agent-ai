use tauri::{AppHandle, LogicalSize, Manager, PhysicalPosition, PhysicalSize};

const PILL: (f64, f64) = (200.0, 32.0);
const PANEL: (f64, f64) = (760.0, 540.0);
const TOP_MARGIN: f64 = 6.0;
const WINDOW: (f64, f64) = (1100.0, 720.0);
const WINDOW_MIN: (f64, f64) = (900.0, 600.0);

pub fn apply(app: &AppHandle, mode: &str, focus: bool) -> Result<(), String> {
    let window = app.get_webview_window("main").ok_or("janela principal ausente")?;
    let e = |err: tauri::Error| err.to_string();
    if mode == "window" {
        window.set_always_on_top(false).map_err(e)?;
        window.set_skip_taskbar(false).map_err(e)?;
        window.set_decorations(true).map_err(e)?;
        window.set_resizable(true).map_err(e)?;
        window.set_maximizable(true).map_err(e)?;
        window.set_minimizable(true).map_err(e)?;
        window.set_min_size(Some(LogicalSize::new(WINDOW_MIN.0, WINDOW_MIN.1))).map_err(e)?;
        window.set_size(LogicalSize::new(WINDOW.0, WINDOW.1)).map_err(e)?;
        window.center().map_err(e)?;
        window.show().map_err(e)?;
        if focus {
            window.set_focus().map_err(e)?;
        }
        return Ok(());
    }
    let (width, height) = match mode {
        "pill" => PILL,
        "panel" => PANEL,
        other => return Err(format!("modo desconhecido: {other}")),
    };
    if window.is_decorated().map_err(e)? {
        window.set_min_size(None::<LogicalSize<f64>>).map_err(e)?;
        window.unmaximize().map_err(e)?;
        window.set_maximizable(false).map_err(e)?;
        window.set_minimizable(false).map_err(e)?;
        window.set_resizable(false).map_err(e)?;
        window.set_decorations(false).map_err(e)?;
        window.set_skip_taskbar(true).map_err(e)?;
        window.set_always_on_top(true).map_err(e)?;
    }
    let monitor = app
        .primary_monitor()
        .map_err(|e| e.to_string())?
        .ok_or("nenhum monitor principal")?;

    let scale = monitor.scale_factor();
    let w = (width * scale).round() as i32;
    let h = (height * scale).round() as i32;
    let x = monitor.position().x + (monitor.size().width as i32 - w) / 2;
    let y = monitor.position().y + (TOP_MARGIN * scale).round() as i32;

    window.set_size(PhysicalSize::new(w as u32, h as u32)).map_err(|e| e.to_string())?;
    window.set_position(PhysicalPosition::new(x, y)).map_err(|e| e.to_string())?;
    window.show().map_err(|e| e.to_string())?;
    if focus {
        window.set_focus().map_err(|e| e.to_string())?;
    }
    Ok(())
}
