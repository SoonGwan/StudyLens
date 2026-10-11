use super::{normalized, CaptureError, SelectionError};
use base64::Engine;
use serde::Deserialize;
use std::io::Cursor;
use std::sync::Mutex;
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};
use tokio::sync::oneshot;
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationTextPattern, UIA_TextPatternId,
};

/// Reads the selection through UI Automation's TextPattern on the focused element and its
/// ancestors. Secure (password) elements are rejected before any text is read.
#[derive(Default)]
pub struct SelectionReader;

impl SelectionReader {
    pub async fn read(&self, _prompt: bool) -> Result<String, SelectionError> {
        tokio::task::spawn_blocking(|| {
            // Browsers may build their accessibility tree lazily; retry briefly like macOS.
            for attempt in 0..6 {
                match read_selection() {
                    Err(SelectionError::NoSelection) if attempt < 5 => std::thread::sleep(std::time::Duration::from_millis(300)),
                    other => return other,
                }
            }
            Err(SelectionError::NoSelection)
        })
        .await
        .map_err(|e| SelectionError::Helper(e.to_string()))?
    }

    pub async fn warm_up(&self) {}
}

fn read_selection() -> Result<String, SelectionError> {
    let helper = |e: windows::core::Error| SelectionError::Helper(e.message().to_string());
    // SAFETY: COM is initialised on this blocking thread before any UI Automation call.
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let automation: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).map_err(helper)?;
        let walker = automation.ControlViewWalker().map_err(helper)?;
        let focused = automation.GetFocusedElement().map_err(|_| SelectionError::NoFocusedApplication)?;
        let mut chain: Vec<IUIAutomationElement> = vec![focused];
        while chain.len() < 12 {
            match walker.GetParentElement(chain.last().unwrap()) {
                Ok(parent) => chain.push(parent),
                Err(_) => break,
            }
        }
        if chain.iter().any(|e| e.CurrentIsPassword().map(|b| b.as_bool()).unwrap_or(false)) {
            return Err(SelectionError::SecureInput);
        }
        for element in &chain {
            if let Some(text) = selected_text(element)? {
                return Ok(text);
            }
        }
        Err(SelectionError::NoSelection)
    }
}

unsafe fn selected_text(element: &IUIAutomationElement) -> Result<Option<String>, SelectionError> {
    let Ok(pattern) = element.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId) else { return Ok(None) };
    let Ok(ranges) = pattern.GetSelection() else { return Ok(None) };
    let count = ranges.Length().unwrap_or(0);
    let mut parts = Vec::new();
    for index in 0..count {
        if let Ok(range) = ranges.GetElement(index) {
            if let Ok(text) = range.GetText(120_001) {
                parts.push(text.to_string());
            }
        }
    }
    normalized(&parts.join("\n"))
}

#[derive(Debug, Clone, Copy, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

struct Pending {
    data_url: String,
    done: oneshot::Sender<Option<Rect>>,
}

static PENDING: Mutex<Option<Pending>> = Mutex::new(None);

/// Freezes the primary monitor, lets the user drag a region on a full-screen overlay and
/// crops the frozen image. Esc or a click without dragging cancels.
pub async fn capture_region(app: &tauri::AppHandle, _prompt: bool) -> Result<Vec<u8>, CaptureError> {
    let failed = |e: String| CaptureError::LaunchFailed(e);
    // xcap handles aren't Send: finish with them before the first await.
    let (image, x, y, scale) = {
        let monitors = xcap::Monitor::all().map_err(|e| failed(e.to_string()))?;
        let monitor = monitors.into_iter().find(|m| m.is_primary().unwrap_or(false)).ok_or(CaptureError::Empty)?;
        let image = monitor.capture_image().map_err(|e| failed(e.to_string()))?;
        (image, monitor.x().unwrap_or(0), monitor.y().unwrap_or(0), monitor.scale_factor().unwrap_or(1.0) as f64)
    };

    let mut png = Vec::new();
    image::DynamicImage::ImageRgba8(image.clone())
        .write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png)
        .map_err(|e| failed(e.to_string()))?;
    let (tx, rx) = oneshot::channel();
    *PENDING.lock().unwrap() = Some(Pending {
        data_url: format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(&png)),
        done: tx,
    });

    let window = WebviewWindowBuilder::new(app, "capture-overlay", WebviewUrl::App("overlay.html".into()))
        .position(x as f64 / scale, y as f64 / scale)
        .inner_size(image.width() as f64 / scale, image.height() as f64 / scale)
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(false)
        .focused(true)
        .build()
        .map_err(|e| failed(e.to_string()))?;
    let selection = rx.await.ok().flatten();
    let _ = window.close();
    if let Some(window) = app.get_webview_window("capture-overlay") {
        let _ = window.close();
    }

    let rect = selection.ok_or(CaptureError::Cancelled)?;
    let left = (rect.x * scale).round().max(0.0) as u32;
    let top = (rect.y * scale).round().max(0.0) as u32;
    let width = ((rect.width * scale).round() as u32).min(image.width().saturating_sub(left));
    let height = ((rect.height * scale).round() as u32).min(image.height().saturating_sub(top));
    if width < 4 || height < 4 {
        return Err(CaptureError::Cancelled);
    }
    let cropped = image::imageops::crop_imm(&image, left, top, width, height).to_image();
    let mut out = Vec::new();
    image::DynamicImage::ImageRgba8(cropped)
        .write_to(&mut Cursor::new(&mut out), image::ImageFormat::Png)
        .map_err(|_| CaptureError::Empty)?;
    Ok(out)
}

/// Windows has no per-app screen or accessibility permission to report.
pub fn permission_status() -> Option<(bool, bool)> {
    None
}

pub fn overlay_image() -> Option<String> {
    PENDING.lock().unwrap().as_ref().map(|p| p.data_url.clone())
}

pub fn finish_overlay(rect: Option<Rect>) {
    if let Some(pending) = PENDING.lock().unwrap().take() {
        let _ = pending.done.send(rect);
    }
}
