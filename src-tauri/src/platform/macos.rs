use super::{CaptureError, SelectionError};
use serde_json::{json, Value};
use std::os::unix::fs::DirBuilderExt;
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

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> bool;
}

/// What macOS currently allows this running app (not whether a given app exposes its selection).
pub fn permission_status() -> Option<(bool, bool)> {
    // SAFETY: argument-free status queries.
    unsafe { Some((AXIsProcessTrusted(), CGPreflightScreenCaptureAccess())) }
}

/// The system's own crosshair selection (`screencapture -i`): Esc cancels, nothing else
/// is captured.
/// `prompt` is false for the silent code-copy flow: no permission dialog, just an error.
pub async fn capture_region(_app: &tauri::AppHandle, prompt: bool) -> Result<Vec<u8>, CaptureError> {
    // SAFETY: plain CoreGraphics calls without arguments.
    let granted = unsafe { CGPreflightScreenCaptureAccess() || (prompt && CGRequestScreenCaptureAccess()) };
    if !granted {
        return Err(CaptureError::PermissionDenied);
    }
    let capture = CaptureDirectory::new()?;
    let mut command = Command::new("/usr/sbin/screencapture");
    command.args(["-i", "-s", "-x", "-t", "png"]).arg(capture.image_path());
    capture_output(command, capture).await
}

/// Removing the directory also prevents a cancelled child from recreating its output
/// after cleanup. Only this capture owns the directory; no other app's files are touched.
struct CaptureDirectory(PathBuf);

impl CaptureDirectory {
    fn new() -> Result<Self, CaptureError> {
        let path = std::env::temp_dir().join(format!("StudyLens-{}", uuid::Uuid::new_v4()));
        std::fs::DirBuilder::new().mode(0o700).create(&path)
            .map_err(|e| CaptureError::LaunchFailed(e.to_string()))?;
        Ok(Self(path))
    }

    fn image_path(&self) -> PathBuf {
        self.0.join("capture.png")
    }
}

impl Drop for CaptureDirectory {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_dir_all(&self.0) {
            if error.kind() != std::io::ErrorKind::NotFound {
                eprintln!("capture cleanup failed: {error}");
            }
        }
    }
}

async fn capture_output(mut command: Command, capture: CaptureDirectory) -> Result<Vec<u8>, CaptureError> {
    let status = command
        .kill_on_drop(true)
        .status()
        .await
        .map_err(|e| CaptureError::LaunchFailed(e.to_string()))?;
    let data = tokio::fs::read(capture.image_path()).await.ok();
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

#[cfg(test)]
mod capture_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn synthetic_command(script: &str, capture: &CaptureDirectory) -> Command {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", script, "capture-test"]).arg(capture.image_path());
        command
    }

    #[tokio::test]
    async fn success_reads_output_and_removes_private_directory() {
        let capture = CaptureDirectory::new().unwrap();
        let directory = capture.0.clone();
        assert_eq!(std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777, 0o700);
        let command = synthetic_command("printf synthetic-image > \"$1\"", &capture);
        assert_eq!(capture_output(command, capture).await.unwrap(), b"synthetic-image");
        assert!(!directory.exists());
    }

    #[tokio::test]
    async fn selection_cancel_without_output_removes_directory() {
        let capture = CaptureDirectory::new().unwrap();
        let directory = capture.0.clone();
        let command = synthetic_command("exit 0", &capture);
        assert_eq!(capture_output(command, capture).await, Err(CaptureError::Cancelled));
        assert!(!directory.exists());
    }

    #[tokio::test]
    async fn empty_output_removes_directory() {
        let capture = CaptureDirectory::new().unwrap();
        let directory = capture.0.clone();
        let command = synthetic_command(": > \"$1\"", &capture);
        assert_eq!(capture_output(command, capture).await, Err(CaptureError::Empty));
        assert!(!directory.exists());
    }

    #[tokio::test]
    async fn failed_capture_removes_partial_output() {
        let capture = CaptureDirectory::new().unwrap();
        let directory = capture.0.clone();
        let command = synthetic_command("printf partial-image > \"$1\"; exit 1", &capture);
        assert_eq!(capture_output(command, capture).await, Err(CaptureError::Cancelled));
        assert!(!directory.exists());
    }

    #[tokio::test]
    async fn launch_failure_removes_directory() {
        let capture = CaptureDirectory::new().unwrap();
        let directory = capture.0.clone();
        let command = Command::new(directory.join("missing-executable"));
        assert!(matches!(capture_output(command, capture).await, Err(CaptureError::LaunchFailed(_))));
        assert!(!directory.exists());
    }

    #[tokio::test]
    async fn abort_during_capture_removes_written_image_and_directory() {
        let capture = CaptureDirectory::new().unwrap();
        let directory = capture.0.clone();
        let image = capture.image_path();
        let command = synthetic_command("printf private-synthetic-image > \"$1\"; exec /bin/sleep 30", &capture);
        let task = tokio::spawn(capture_output(command, capture));
        let written = tokio::time::timeout(Duration::from_secs(5), async {
            while !image.exists() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        }).await;
        task.abort();
        let stopped = task.await;
        assert!(written.is_ok(), "synthetic capture did not create its output");
        assert!(stopped.unwrap_err().is_cancelled());
        assert!(!image.exists());
        assert!(!directory.exists());
    }
}
