//! Official "Sign in with ChatGPT": the app registers its own client, uses PKCE, state and
//! nonce, and verifies the ID token signature. It never reads other apps' login files.

pub mod chatgpt;
pub mod loopback;
pub mod oidc;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rand::RngCore;
use sha2::{Digest, Sha256};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AuthError {
    #[error("설정에서 Continue with ChatGPT를 눌러 계정을 연결해 주세요.")]
    NotConnected,
    #[error("이 연결에는 구독 사용 권한이 없습니다. 설정에서 구독 사용 허용을 눌러 주세요.")]
    PermissionMissing,
    #[error("로그인 응답을 확인할 수 없습니다. 다시 로그인해 주세요.")]
    InvalidCallback,
    #[error("ChatGPT 연결을 허용하지 않았습니다.")]
    Denied,
    #[error("ChatGPT 로그인 서명 또는 계정 정보를 검증하지 못했습니다.")]
    InvalidIdentity,
    #[error("로그인을 취소했습니다.")]
    Cancelled,
    #[error("로그인 시간이 초과되었습니다. 다시 시도해 주세요.")]
    TimedOut,
    #[error("ChatGPT 연결 오류: {0}. 설정에서 연결 상태를 확인해 주세요.")]
    OAuth(String),
    #[error("{0}")]
    Storage(String),
}

pub fn random_value() -> String {
    let mut bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

/// `application/x-www-form-urlencoded` with only RFC 3986 unreserved characters left as-is.
pub fn form(fields: &[(&str, &str)]) -> String {
    let mut fields = fields.to_vec();
    fields.sort_by_key(|(k, _)| *k);
    fields.iter().map(|(k, v)| format!("{}={}", encode(k), encode(v))).collect::<Vec<_>>().join("&")
}

fn encode(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_reference_vector() {
        assert_eq!(challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }

    #[test]
    fn form_encoding_escapes_reserved_characters() {
        assert!(form(&[("code", "a+b&c=d /?")]).contains("code=a%2Bb%26c%3Dd%20%2F%3F"));
    }
}
