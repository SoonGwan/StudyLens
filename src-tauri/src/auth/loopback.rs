//! One-shot login callback listening only on IPv4 loopback while a sign-in is in progress.

use super::AuthError;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Notify;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Callback {
    pub code: String,
    pub client_id: Option<String>,
    pub redirect_uri: String,
}

pub fn parse(url: &str, expected_state: &str, redirect_uri: &str) -> Result<Callback, AuthError> {
    let invalid = || AuthError::InvalidCallback;
    let url = url::Url::parse(url).map_err(|_| invalid())?;
    let expected = url::Url::parse(redirect_uri).map_err(|_| invalid())?;
    if url.scheme() != expected.scheme() || url.host() != expected.host() || url.port() != expected.port() || url.path() != expected.path() {
        return Err(invalid());
    }
    let items: Vec<(String, String)> = url.query_pairs().into_owned().collect();
    let mut names: Vec<&str> = items.iter().map(|(k, _)| k.as_str()).collect();
    names.sort();
    names.dedup();
    let get = |name: &str| items.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone());
    // Reject ambiguous duplicate parameters.
    if names.len() != items.len() || get("state").as_deref() != Some(expected_state) {
        return Err(invalid());
    }
    if let Some(error) = get("error") {
        return Err(if error == "access_denied" { AuthError::Denied } else { AuthError::OAuth(error) });
    }
    let code = get("code").filter(|c| !c.is_empty()).ok_or_else(invalid)?;
    Ok(Callback { code, client_id: get("client_id"), redirect_uri: redirect_uri.to_string() })
}

/// Opens the browser via `open` with the redirect URI, then waits for a valid callback.
/// Invalid requests are answered and ignored; `cancel` or a 3-minute timeout ends the wait.
pub async fn authorize(
    expected_state: &str,
    open: impl FnOnce(&str) -> Result<(), AuthError>,
    cancel: Arc<Notify>,
) -> Result<Callback, AuthError> {
    let listener = TcpListener::bind("127.0.0.1:0").await.map_err(|_| AuthError::OAuth("callback_listener_failed".into()))?;
    let port = listener.local_addr().map_err(|_| AuthError::InvalidCallback)?.port();
    let redirect_uri = format!("http://127.0.0.1:{port}/auth/callback");
    open(&redirect_uri)?;
    let wait = async {
        loop {
            let Ok((stream, _)) = listener.accept().await else { continue };
            if let Some(result) = handle(stream, expected_state, &redirect_uri, port).await {
                return result;
            }
        }
    };
    tokio::select! {
        result = wait => result,
        _ = cancel.notified() => Err(AuthError::Cancelled),
        _ = tokio::time::sleep(Duration::from_secs(180)) => Err(AuthError::TimedOut),
    }
}

/// `None` keeps listening (bad or unrelated request); `Some` ends the sign-in attempt.
async fn handle(mut stream: TcpStream, state: &str, redirect_uri: &str, port: u16) -> Option<Result<Callback, AuthError>> {
    let mut buffer = Vec::new();
    let header_end = loop {
        let mut chunk = [0u8; 4096];
        let n = tokio::time::timeout(Duration::from_secs(10), stream.read(&mut chunk)).await.ok()?.ok()?;
        if n == 0 || buffer.len() + n > 16_384 {
            return None;
        }
        buffer.extend_from_slice(&chunk[..n]);
        if let Some(end) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
            break end;
        }
    };
    let head = String::from_utf8_lossy(&buffer[..header_end]).into_owned();
    let parts: Vec<&str> = head.lines().next().unwrap_or_default().split(' ').collect();
    if parts.len() != 3 || parts[0] != "GET" || !parts[1].starts_with("/auth/callback?") {
        respond(&mut stream, "404 Not Found", "StudyLens login callback only.").await;
        return None;
    }
    match parse(&format!("http://127.0.0.1:{port}{}", parts[1]), state, redirect_uri) {
        Ok(callback) => {
            respond(&mut stream, "200 OK", "StudyLens received your login. You can return to the app.").await;
            Some(Ok(callback))
        }
        Err(AuthError::InvalidCallback) => {
            respond(&mut stream, "400 Bad Request", "Invalid login callback.").await;
            None
        }
        Err(error) => {
            respond(&mut stream, "400 Bad Request", "Login was not completed.").await;
            Some(Err(error))
        }
    }
}

async fn respond(stream: &mut TcpStream, status: &str, message: &str) {
    let reply = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{message}",
        message.len()
    );
    let _ = stream.write_all(reply.as_bytes()).await;
    let _ = stream.shutdown().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn callback_checks_state_path_and_duplicates() {
        let redirect = "http://127.0.0.1:54321/auth/callback";
        let callback = parse(&format!("{redirect}?state=expected&code=abc&client_id=oaiapp_test"), "expected", redirect).unwrap();
        assert_eq!(callback.code, "abc");
        assert_eq!(callback.client_id.as_deref(), Some("oaiapp_test"));
        for url in [
            format!("{redirect}?state=wrong&code=abc"),
            format!("{redirect}?state=expected&state=wrong&code=abc"),
            "http://localhost:54321/auth/callback?state=expected&code=abc".into(),
            "http://127.0.0.1:54321/callback?state=expected&code=abc".into(),
        ] {
            assert!(parse(&url, "expected", redirect).is_err(), "{url}");
        }
        assert_eq!(parse(&format!("{redirect}?state=expected&error=access_denied"), "expected", redirect).unwrap_err(), AuthError::Denied);
    }

    async fn get(uri: &str) -> u16 {
        let address = uri.trim_start_matches("http://").split('/').next().unwrap().to_string();
        let path = &uri[uri.find("/auth").unwrap()..];
        let mut stream = TcpStream::connect(address).await.unwrap();
        stream.write_all(format!("GET {path} HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes()).await.unwrap();
        let mut reply = String::new();
        stream.read_to_string(&mut reply).await.unwrap();
        reply.split(' ').nth(1).unwrap().parse().unwrap()
    }

    #[tokio::test]
    async fn ignores_bad_state_then_accepts_correct_callback() {
        let (tx, rx) = tokio::sync::oneshot::channel();
        let client = tokio::spawn(async move {
            let uri: String = rx.await.unwrap();
            assert_eq!(get(&format!("{uri}?state=wrong&code=abc")).await, 400);
            assert_eq!(get(&format!("{uri}?state=expected&code=abc&client_id=oaiapp_test")).await, 200);
        });
        let callback = authorize("expected", |uri| { tx.send(uri.to_string()).unwrap(); Ok(()) }, Arc::new(Notify::new())).await.unwrap();
        client.await.unwrap();
        assert_eq!(callback.code, "abc");
        assert!(callback.redirect_uri.starts_with("http://127.0.0.1:"));
    }

    #[tokio::test]
    async fn can_be_cancelled() {
        let cancel = Arc::new(Notify::new());
        let trigger = cancel.clone();
        let result = authorize("s", move |_| { trigger.notify_one(); Ok(()) }, cancel).await;
        assert_eq!(result.unwrap_err(), AuthError::Cancelled);
    }
}
