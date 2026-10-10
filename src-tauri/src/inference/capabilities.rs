//! What each model is known to accept. Exact aliases verified in official model docs;
//! unknown aliases and snapshots fail closed (no reasoning field, no image attachment).

use crate::settings::{BillingMode, Settings};

const ADJUSTABLE_REASONING: &[&str] = &["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.2", "gpt-5.1", "gpt-5"];
const IMAGE_ONLY: &[&str] = &["gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini"];

pub const MODEL_DEFAULT: &str = "modelDefault";
pub const MAX_TEXT_CHARS: usize = 30_000;
pub const MAX_INSTRUCTION_CHARS: usize = 2_000;
pub const MAX_IMAGE_BYTES: usize = 10 * 1024 * 1024;

pub fn supports_image(model: &str) -> bool {
    ADJUSTABLE_REASONING.contains(&model) || IMAGE_ONLY.contains(&model)
}

/// Choices offered in settings for this model, in display order.
pub fn reasoning_choices(model: &str) -> Vec<&'static str> {
    if ADJUSTABLE_REASONING.contains(&model) {
        vec!["low", "medium", "high", MODEL_DEFAULT]
    } else {
        vec![MODEL_DEFAULT]
    }
}

/// The `reasoning.effort` value to send, or `None` to omit the field.
pub fn validated_effort(effort: &str, model: &str) -> Option<String> {
    (effort != MODEL_DEFAULT && reasoning_choices(model).contains(&effort)).then(|| effort.to_string())
}

pub fn preference_key(mode: BillingMode, model: &str) -> String {
    let mode = serde_json::to_value(mode).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
    format!("{mode}:{model}")
}

/// Stored per mode and model; unsupported stored values fall back to the model default.
/// New adjustable models start at `low`.
pub fn preference(settings: &Settings, mode: BillingMode, model: &str) -> String {
    let allowed = reasoning_choices(model);
    match settings.reasoning.get(&preference_key(mode, model)) {
        Some(stored) if allowed.contains(&stored.as_str()) => stored.clone(),
        Some(_) => MODEL_DEFAULT.into(),
        None if allowed.contains(&"low") => "low".into(),
        None => MODEL_DEFAULT.into(),
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum InputError {
    #[error("선택 본문은 비어 있지 않은 30,000자 이하의 텍스트여야 합니다.")]
    SelectionTooLong,
    #[error("추가 지시는 2,000자 이하로 입력해 주세요.")]
    InstructionsTooLong,
    #[error("이 모델의 이미지 입력 지원을 확인하지 못했습니다. 그림 첨부를 끄거나 이미지 지원이 확인된 모델을 선택하세요.")]
    UnsupportedImageModel,
    #[error("그림 첨부는 PNG 한 장, 10 MiB 이하로 제한합니다. 더 작은 영역을 선택해 주세요.")]
    ImageTooLarge,
    #[error("첨부할 PNG 이미지를 읽지 못했습니다. 그림 영역을 다시 선택해 주세요.")]
    InvalidImage,
}

pub fn validate_text(text: &str, instructions: &str) -> Result<(), InputError> {
    if text.trim().is_empty() || text.chars().count() > MAX_TEXT_CHARS {
        return Err(InputError::SelectionTooLong);
    }
    if instructions.chars().count() > MAX_INSTRUCTION_CHARS {
        return Err(InputError::InstructionsTooLong);
    }
    Ok(())
}

pub fn validate_image(png: &[u8], model: &str) -> Result<(), InputError> {
    if !supports_image(model) {
        return Err(InputError::UnsupportedImageModel);
    }
    if png.len() > MAX_IMAGE_BYTES {
        return Err(InputError::ImageTooLarge);
    }
    let decoded = image::load_from_memory_with_format(png, image::ImageFormat::Png);
    if !png.starts_with(b"\x89PNG\r\n\x1a\n") || decoded.is_err() {
        return Err(InputError::InvalidImage);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reasoning_is_offered_only_for_verified_aliases() {
        assert_eq!(reasoning_choices("gpt-6.1-sol"), ["low", "medium", "high", MODEL_DEFAULT]);
        assert_eq!(reasoning_choices("gpt-5.2-2026-01-01"), [MODEL_DEFAULT]);
        assert_eq!(validated_effort("medium", "gpt-5"), Some("medium".into()));
        assert_eq!(validated_effort("medium", "gpt-4.1-mini"), None);
        assert_eq!(validated_effort("minimal", "gpt-6.1-sol"), None);
        assert_eq!(validated_effort(MODEL_DEFAULT, "gpt-5"), None);
    }

    #[test]
    fn preference_defaults_to_low_and_rejects_stale_values() {
        let mut settings = Settings::default();
        assert_eq!(preference(&settings, BillingMode::ApiKey, "gpt-5.1"), "low");
        assert_eq!(preference(&settings, BillingMode::ApiKey, "gpt-4.1-mini"), MODEL_DEFAULT);
        settings.reasoning.insert(preference_key(BillingMode::ApiKey, "gpt-5.1"), "high".into());
        assert_eq!(preference(&settings, BillingMode::ApiKey, "gpt-5.1"), "high");
        assert_eq!(preference(&settings, BillingMode::ChatGpt, "gpt-5.1"), "low", "stored per mode");
        settings.reasoning.insert(preference_key(BillingMode::ApiKey, "gpt-5.1"), "extreme".into());
        assert_eq!(preference(&settings, BillingMode::ApiKey, "gpt-5.1"), MODEL_DEFAULT);
    }

    #[test]
    fn inputs_are_checked_before_sending() {
        assert_eq!(validate_text("  ", ""), Err(InputError::SelectionTooLong));
        assert_eq!(validate_text(&"a".repeat(30_001), ""), Err(InputError::SelectionTooLong));
        assert_eq!(validate_text("문제", &"a".repeat(2_001)), Err(InputError::InstructionsTooLong));
        assert!(validate_text("문제", "Java로").is_ok());

        let mut png = Vec::new();
        image::DynamicImage::new_rgba8(2, 2).write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        assert!(validate_image(&png, "gpt-4.1-mini").is_ok());
        assert_eq!(validate_image(&png, "unknown-model"), Err(InputError::UnsupportedImageModel));
        assert_eq!(validate_image(b"not a png", "gpt-5"), Err(InputError::InvalidImage));
        assert_eq!(validate_image(&vec![0; MAX_IMAGE_BYTES + 1], "gpt-5"), Err(InputError::ImageTooLarge));
    }
}
