use tauri::{AppHandle, Manager, PhysicalPosition, PhysicalSize};

const PILL: (f64, f64) = (200.0, 32.0);
const PANEL: (f64, f64) = (760.0, 540.0);
const TOP_MARGIN: f64 = 6.0;

pub fn apply(app: &AppHandle, mode: &str, focus: bool) -> Result<(), String> {
    let (width, height) = match mode {
        "pill" => PILL,
        "panel" => PANEL,
        other => return Err(format!("modo desconhecido: {other}")),
    };
    let window = app.get_webview_window("main").ok_or("janela principal ausente")?;
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
