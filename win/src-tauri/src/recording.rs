use std::sync::atomic::{AtomicBool, Ordering};

use tauri::image::Image;
use tauri::{AppHandle, Manager, State};

pub const TRAY_ID: &str = "wisp-tray";
pub const TOOLTIP_IDLE: &str = "Wisp";
pub const TOOLTIP_RECORDING: &str = "Wisp · gravando";

const RED: [u8; 4] = [0xF2, 0x55, 0x5A, 0xFF];
const RING: [u8; 4] = [0x11, 0x12, 0x14, 0xFF];

#[derive(Default)]
pub struct RecordingState {
    active: AtomicBool,
}

pub fn tooltip(active: bool) -> &'static str {
    if active {
        TOOLTIP_RECORDING
    } else {
        TOOLTIP_IDLE
    }
}

pub fn with_red_dot(rgba: &[u8], width: u32, height: u32) -> Vec<u8> {
    let (w, h) = (width as usize, height as usize);
    let mut out = rgba.to_vec();
    if w == 0 || h == 0 || rgba.len() != w * h * 4 {
        return out;
    }
    let radius = (w.min(h) as f32) * 0.18;
    let ring = radius * 1.35;
    let (cx, cy) = (w as f32 - ring - 0.5, h as f32 - ring - 0.5);
    for y in 0..h {
        for x in 0..w {
            let d = ((x as f32 - cx).powi(2) + (y as f32 - cy).powi(2)).sqrt();
            let colour = if d <= radius {
                RED
            } else if d <= ring {
                RING
            } else {
                continue;
            };
            let at = (y * w + x) * 4;
            out[at..at + 4].copy_from_slice(&colour);
        }
    }
    out
}

fn base_icon() -> Result<Image<'static>, String> {
    Image::from_bytes(include_bytes!("../icons/icon.png")).map_err(|e| e.to_string())
}

fn recording_icon() -> Result<Image<'static>, String> {
    let base = base_icon()?;
    Ok(Image::new_owned(with_red_dot(base.rgba(), base.width(), base.height()), base.width(), base.height()))
}

pub fn apply(app: &AppHandle, active: bool) -> Result<(), String> {
    let tray = app.tray_by_id(TRAY_ID).ok_or("ícone da bandeja ausente")?;
    let icon = if active { recording_icon()? } else { base_icon()? };
    tray.set_icon(Some(icon)).map_err(|e| e.to_string())?;
    tray.set_tooltip(Some(tooltip(active))).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn set_recording(app: AppHandle, state: State<'_, RecordingState>, active: bool) -> Result<(), String> {
    if state.active.swap(active, Ordering::SeqCst) == active {
        return Ok(());
    }
    apply(&app, active)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blank(w: u32, h: u32) -> Vec<u8> {
        vec![0x20; (w * h * 4) as usize]
    }

    fn px(buf: &[u8], w: u32, x: u32, y: u32) -> [u8; 4] {
        let at = ((y * w + x) * 4) as usize;
        [buf[at], buf[at + 1], buf[at + 2], buf[at + 3]]
    }

    #[test]
    fn the_dot_is_red_in_the_bottom_right_and_the_rest_is_untouched() {
        let base = blank(32, 32);
        let out = with_red_dot(&base, 32, 32);
        assert_eq!(out.len(), base.len());
        assert_eq!(px(&out, 32, 26, 26), RED);
        assert_eq!(px(&out, 32, 2, 2), [0x20; 4]);
        assert_eq!(px(&out, 32, 30, 2), [0x20; 4]);
        assert_eq!(px(&out, 32, 2, 30), [0x20; 4]);
    }

    #[test]
    fn a_buffer_that_is_not_rgba_of_that_size_comes_back_unchanged() {
        assert_eq!(with_red_dot(&[1, 2, 3], 32, 32), vec![1, 2, 3]);
        assert_eq!(with_red_dot(&[], 0, 0), Vec::<u8>::new());
    }

    #[test]
    fn the_tooltip_says_recording_only_while_recording() {
        assert_eq!(tooltip(true), "Wisp · gravando");
        assert_eq!(tooltip(false), "Wisp");
    }
}
