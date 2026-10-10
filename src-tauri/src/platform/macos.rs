use super::{CaptureError, SelectionError};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestScreenCaptureAccess() -> bool;
}

/// The system's own crosshair selection (`screencapture -i`): Esc cancels, nothing else
/// is captured.
pub async fn capture_region(_app: &tauri::AppHandle) -> Result<Vec<u8>, CaptureError> {
    // SAFETY: plain CoreGraphics calls without arguments.
    let granted = unsafe { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() };
    if !granted {
        return Err(CaptureError::PermissionDenied);
    }
    let target = std::env::temp_dir().join(format!("StudyLens-{}.png", uuid::Uuid::new_v4()));
    let status = Command::new("/usr/sbin/screencapture")
        .args(["-i", "-x", "-t", "png"])
        .arg(&target)
        .kill_on_drop(true)
        .status()
        .await
        .map_err(|e| CaptureError::LaunchFailed(e.to_string()))?;
    let data = tokio::fs::read(&target).await.ok();
    let _ = tokio::fs::remove_file(&target).await;
    if !status.success() {
        return Err(CaptureError::Cancelled);
    }
    // Esc exits successfully without writing a file.
    match data {
        Some(data) if !data.is_empty() => Ok(data),
        Some(_) => Err(CaptureError::Empty),
        None => Err(CaptureError::Cancelled),
    }
}

/// Talks to the bundled `studylens-helper` (Swift, Accessibility API). It runs for the
/// app's lifetime so it can remember the last app the user worked in.
#[derive(Default)]
pub struct SelectionReader {
    helper: tokio::sync::Mutex<Option<Helper>>,
}

struct Helper {
    _child: Child,
    stdin: ChildStdin,
    stdout: Lines<BufReader<ChildStdout>>,
    next_id: u64,
}

impl SelectionReader {
    pub async fn read(&self, prompt: bool) -> Result<String, SelectionError> {
        let response = self.request(json!({ "cmd": "selectedText", "prompt": prompt })).await?;
        if response["ok"] == true {
            let text = response["text"].as_str().unwrap_or_default();
            return super::normalized(text)?.ok_or(SelectionError::NoSelection);
        }
        Err(SelectionError::from_code(response["error"].as_str().unwrap_or("noSelection")))
    }

    /// Starts the helper early so it already knows the frontmost app at the first shortcut.
    pub async fn warm_up(&self) {
        let _ = self.request(json!({ "cmd": "ping" })).await;
    }

    async fn request(&self, mut request: Value) -> Result<Value, SelectionError> {
        let mut guard = self.helper.lock().await;
        for attempt in 0..2 {
            if guard.is_none() {
                *guard = Some(spawn_helper()?);
            }
            let helper = guard.as_mut().expect("helper started");
            helper.next_id += 1;
            let id = helper.next_id;
            request["id"] = json!(id);
            match exchange(helper, &request, id).await {
                Ok(response) => return Ok(response),
                // A crashed helper is restarted once.
                Err(error) if attempt == 0 => {
                    eprintln!("studylens-helper restart: {error}");
                    *guard = None;
                }
                Err(error) => {
                    *guard = None;
                    return Err(SelectionError::Helper(error));
                }
            }
        }
        unreachable!()
    }
}

async fn exchange(helper: &mut Helper, request: &Value, id: u64) -> Result<Value, String> {
    let mut line = serde_json::to_vec(request).map_err(|e| e.to_string())?;
    line.push(b'\n');
    helper.stdin.write_all(&line).await.map_err(|e| e.to_string())?;
    helper.stdin.flush().await.map_err(|e| e.to_string())?;
    // Selection reading retries for up to ~3s inside the helper.
    let read = async {
        while let Some(line) = helper.stdout.next_line().await.map_err(|e| e.to_string())? {
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                if value["id"] == id {
                    return Ok(value);
                }
            }
        }
        Err("helper exited".to_string())
    };
    tokio::time::timeout(Duration::from_secs(10), read).await.map_err(|_| "helper timed out".to_string())?
}

fn helper_path() -> Result<PathBuf, SelectionError> {
    let exe = std::env::current_exe().map_err(|e| SelectionError::Helper(e.to_string()))?;
    let path = exe.with_file_name("studylens-helper");
    if path.exists() {
        Ok(path)
    } else {
        Err(SelectionError::Helper(format!("{} 없음", path.display())))
    }
}

fn spawn_helper() -> Result<Helper, SelectionError> {
    let mut child = Command::new(helper_path()?)
        .args(["serve", "--owner-pid", &std::process::id().to_string()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| SelectionError::Helper(e.to_string()))?;
    let stdin = child.stdin.take().expect("piped stdin");
    let stdout = BufReader::new(child.stdout.take().expect("piped stdout")).lines();
    Ok(Helper { _child: child, stdin, stdout, next_id: 0 })
}
