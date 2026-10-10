//! OS-specific pieces: interactive region capture and reading the selection in other apps.
//! Neither path sends copy keystrokes or reads the clipboard.

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::{capture_region, SelectionReader};

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use self::windows::{capture_region, finish_overlay, overlay_image, SelectionReader};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CaptureError {
    #[error("화면 기록 권한이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 StudyLens를 허용한 뒤 앱을 다시 실행해 주세요.")]
    PermissionDenied,
    #[error("캡처가 취소되었습니다.")]
    Cancelled,
    #[error("화면 캡처를 시작하지 못했습니다: {0}")]
    LaunchFailed(String),
    #[error("선택한 영역에서 이미지를 만들지 못했습니다. 다시 시도해 주세요.")]
    Empty,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SelectionError {
    #[error("{}", permission_message())]
    PermissionDenied,
    #[error("텍스트가 있는 앱을 클릭한 뒤 내용을 드래그하고 선택 텍스트 단축키를 눌러 주세요.")]
    NoFocusedApplication,
    #[error("선택 텍스트를 읽지 못했습니다. 텍스트를 다시 드래그한 뒤 단축키를 눌러 주세요. 지원하지 않는 앱이나 이미지 속 글자는 영역 캡처를 사용하세요.")]
    NoSelection,
    #[error("비밀번호 등 보안 입력 영역은 읽지 않습니다. 일반 학습 텍스트를 선택해 주세요.")]
    SecureInput,
    #[error("선택한 내용이 너무 깁니다. 30,000자 이하로 나누어 선택해 주세요.")]
    SelectionTooLong,
    #[error("선택 텍스트 도우미를 실행하지 못했습니다: {0}")]
    Helper(String),
}

fn permission_message() -> &'static str {
    if cfg!(target_os = "macos") {
        "접근성 권한이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 StudyLens를 허용해 주세요. 업데이트 후에는 항목을 다시 등록하고 앱을 재실행해야 할 수 있습니다."
    } else {
        "선택한 텍스트에 접근할 수 없습니다. 관리자 권한으로 실행 중인 앱은 읽을 수 없습니다."
    }
}

impl SelectionError {
    pub fn from_code(code: &str) -> Self {
        match code {
            "permissionDenied" => Self::PermissionDenied,
            "noFocusedApplication" => Self::NoFocusedApplication,
            "secureInput" => Self::SecureInput,
            "selectionTooLong" => Self::SelectionTooLong,
            "noSelection" => Self::NoSelection,
            other => Self::Helper(other.to_string()),
        }
    }
}

/// Normalizes a selection the same way on every platform.
pub fn normalized(value: &str) -> Result<Option<String>, SelectionError> {
    if value.encode_utf16().count() > 120_000 {
        return Err(SelectionError::SelectionTooLong);
    }
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    if trimmed.chars().count() > 30_000 {
        return Err(SelectionError::SelectionTooLong);
    }
    Ok(Some(trimmed.to_string()))
}

/// Deep links into the OS privacy settings for the permission an error refers to.
pub fn privacy_settings_url(kind: &str) -> Option<&'static str> {
    if cfg!(target_os = "macos") {
        match kind {
            "screen" => Some("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
            "accessibility" => Some("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
            _ => None,
        }
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn helper_codes_map_to_errors() {
        assert_eq!(SelectionError::from_code("secureInput"), SelectionError::SecureInput);
        assert_eq!(SelectionError::from_code("weird"), SelectionError::Helper("weird".into()));
    }

    #[test]
    fn long_selection_is_rejected_not_truncated() {
        assert_eq!(normalized(&"가".repeat(30_001)).unwrap_err(), SelectionError::SelectionTooLong);
        assert_eq!(normalized("  선택\n").unwrap().as_deref(), Some("선택"));
        assert_eq!(normalized("   ").unwrap(), None);
    }
}
