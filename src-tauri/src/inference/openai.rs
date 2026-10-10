//! OpenAI Responses API, used with either a ChatGPT plan token (streamed, no output cap)
//! or a separately billed API key.

use super::sse::{EventFramer, ResponseAccumulator};
use super::{prompts, InferenceError, InferenceProvider};
use async_trait::async_trait;
use base64::Engine;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::Duration;

pub const API_BASE: &str = "https://api.openai.com/v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CredentialKind {
    ChatGpt,
    ApiKey,
}

#[derive(Clone)]
pub struct Credential {
    pub token: String,
    pub kind: CredentialKind,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ChatGptModel {
    #[serde(alias = "slug")]
    pub slug: String,
    #[serde(alias = "display_name")]
    pub display_name: String,
    #[serde(default)]
    pub visibility: Option<String>,
}

#[derive(Clone)]
pub struct OpenAIClient {
    http: reqwest::Client,
    base: String,
}

impl OpenAIClient {
    pub fn new() -> Self {
        Self::with_base(API_BASE)
    }

    pub fn with_base(base: &str) -> Self {
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(15))
            .build()
            .expect("HTTP client");
        Self { http, base: base.trim_end_matches('/').to_string() }
    }

    pub async fn list_chatgpt_models(&self, access_token: &str) -> Result<Vec<ChatGptModel>, InferenceError> {
        #[derive(Deserialize)]
        struct Catalogue {
            models: Vec<ChatGptModel>,
        }
        let response = self
            .http
            .get(format!("{}/models", self.base))
            .bearer_auth(access_token)
            .timeout(Duration::from_secs(30))
            .send()
            .await?;
        let status = response.status().as_u16();
        let body = response.bytes().await?;
        if status != 200 {
            return Err(api_error(status, &serde_json::from_slice(&body).unwrap_or(Value::Null)));
        }
        let catalogue: Catalogue = serde_json::from_slice(&body).map_err(|_| InferenceError::InvalidResponse)?;
        Ok(catalogue.models.into_iter().filter(|m| m.visibility.as_deref() == Some("list")).collect())
    }

    async fn respond(&self, credential: &Credential, payload: Value) -> Result<String, InferenceError> {
        let stream = credential.kind == CredentialKind::ChatGpt;
        let mut request = self
            .http
            .post(format!("{}/responses", self.base))
            .bearer_auth(&credential.token)
            .timeout(Duration::from_secs(if stream { 300 } else { 120 }))
            .json(&payload);
        if stream {
            request = request.header("Accept", "text/event-stream");
        }
        let response = request.send().await?;
        let status = response.status().as_u16();
        if !(200..300).contains(&status) {
            let body = response.bytes().await.unwrap_or_default();
            let body = &body[..body.len().min(65_536)];
            return Err(api_error(status, &serde_json::from_slice(body).unwrap_or(Value::Null)));
        }
        if stream {
            let mut framer = EventFramer::default();
            let mut accumulator = ResponseAccumulator::default();
            let mut bytes = response.bytes_stream();
            while let Some(chunk) = bytes.next().await {
                for event in framer.push(&chunk?)? {
                    if let Some(text) = accumulator.consume(&event)? {
                        return Ok(text);
                    }
                }
            }
            if let Some(event) = framer.finish()? {
                if let Some(text) = accumulator.consume(&event)? {
                    return Ok(text);
                }
            }
            return Err(InferenceError::Interrupted);
        }
        let body: Value = response.json().await.map_err(|_| InferenceError::InvalidResponse)?;
        if body["status"].as_str().is_some_and(|s| s != "completed") {
            return Err(InferenceError::Interrupted);
        }
        let text = body["output"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|item| item["type"] == "message")
            .flat_map(|item| item["content"].as_array().cloned().unwrap_or_default())
            .filter(|c| c["type"] == "output_text")
            .filter_map(|c| c["text"].as_str().map(str::to_string))
            .collect::<Vec<_>>()
            .join("\n");
        let text = text.trim();
        if text.is_empty() {
            return Err(InferenceError::EmptyOutput);
        }
        Ok(text.to_string())
    }
}

/// Maps an error body to a readable message, translating subscription-sharing codes.
pub fn api_error(status: u16, body: &Value) -> InferenceError {
    let code = body["error"]["code"].as_str();
    let message = match code {
        Some("subscription_sharing_usage_limit_exceeded") => {
            "이 앱 또는 ChatGPT 구독의 사용 한도에 도달했습니다. ChatGPT 사용량 설정을 확인해 주세요.".to_string()
        }
        Some("subscription_sharing_user_not_eligible") => "현재 계정·워크스페이스에서는 구독 연동을 사용할 수 없습니다.".to_string(),
        Some("subscription_sharing_usage_unavailable" | "subscription_sharing_user_unavailable") => {
            "현재 구독 사용량을 확인할 수 없습니다. 잠시 후 다시 시도해 주세요.".to_string()
        }
        _ => body["error"]["message"]
            .as_str()
            .or(body["detail"].as_str())
            .unwrap_or("요청이 실패했습니다.")
            .to_string(),
    };
    let message = match code {
        Some(code) => format!("{message} [{code}]"),
        None => message,
    };
    InferenceError::OpenAI { status, message }
}

pub struct OpenAIProvider {
    pub client: OpenAIClient,
    pub credential: Credential,
    pub model: String,
}

impl OpenAIProvider {
    fn payload(&self, instructions: &str, content: Value, api_key_limit: u32) -> Result<Value, InferenceError> {
        if self.model.trim().is_empty() {
            return Err(InferenceError::InvalidModel);
        }
        let mut payload = json!({
            "model": self.model.trim(),
            "instructions": instructions,
            "input": [{ "role": "user", "content": content }],
            "store": false,
            "stream": self.credential.kind == CredentialKind::ChatGpt,
        });
        if self.credential.kind == CredentialKind::ApiKey {
            payload["max_output_tokens"] = json!(api_key_limit);
        }
        Ok(payload)
    }
}

#[async_trait]
impl InferenceProvider for OpenAIProvider {
    async fn explain_image(&self, png: &[u8]) -> Result<String, InferenceError> {
        let url = format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(png));
        let content = json!([
            { "type": "input_text", "text": prompts::IMAGE_REQUEST },
            { "type": "input_image", "image_url": url, "detail": "high" },
        ]);
        let payload = self.payload(prompts::INSTRUCTIONS, content, 2200)?;
        self.client.respond(&self.credential, payload).await
    }

    async fn explain_text(&self, text: &str) -> Result<String, InferenceError> {
        let payload = self.payload(prompts::INSTRUCTIONS, json!([{ "type": "input_text", "text": text }]), 2200)?;
        self.client.respond(&self.credential, payload).await
    }

    async fn generate_code(&self, text: &str, language: &str) -> Result<String, InferenceError> {
        let instructions = prompts::code_instructions(language);
        let payload = self.payload(&instructions, json!([{ "type": "input_text", "text": text }]), 12_000)?;
        self.client.respond(&self.credential, payload).await
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// One-shot HTTP server: records each request and replies with `(status, content type, body)`.
    pub async fn mock(responses: Vec<(u16, &'static str, String)>) -> (String, Arc<Mutex<Vec<(String, Value)>>>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let record = seen.clone();
        tokio::spawn(async move {
            for (status, kind, body) in responses {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut buffer = Vec::new();
                loop {
                    let mut chunk = [0u8; 8192];
                    let n = socket.read(&mut chunk).await.unwrap();
                    buffer.extend_from_slice(&chunk[..n]);
                    let text = String::from_utf8_lossy(&buffer);
                    if let Some(end) = text.find("\r\n\r\n") {
                        let length = text[..end]
                            .lines()
                            .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap()))
                            .unwrap_or(0);
                        if buffer.len() >= end + 4 + length {
                            let head = text[..end].to_string();
                            let json = serde_json::from_slice(&buffer[end + 4..end + 4 + length]).unwrap_or(Value::Null);
                            record.lock().unwrap().push((head, json));
                            break;
                        }
                    }
                    if n == 0 {
                        break;
                    }
                }
                let reply = format!(
                    "HTTP/1.1 {status} X\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.write_all(reply.as_bytes()).await.unwrap();
            }
        });
        (base, seen)
    }

    fn provider(base: &str, kind: CredentialKind) -> OpenAIProvider {
        OpenAIProvider {
            client: OpenAIClient::with_base(base),
            credential: Credential { token: "test-token".into(), kind },
            model: "test-model".into(),
        }
    }

    #[tokio::test]
    async fn plan_image_request_streams_until_completed_event() {
        let events = "event: x\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"단계별 \"}\n\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"설명\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
        let (base, seen) = mock(vec![(200, "text/event-stream", events.into())]).await;
        let result = provider(&base, CredentialKind::ChatGpt).explain_image(&[1, 2, 3]).await.unwrap();
        assert_eq!(result, "단계별 설명");
        let (head, payload) = seen.lock().unwrap()[0].clone();
        assert!(head.to_ascii_lowercase().contains("authorization: bearer test-token"));
        assert_eq!(payload["stream"], true);
        assert_eq!(payload["store"], false);
        assert!(payload.get("max_output_tokens").is_none());
        assert_eq!(payload["input"][0]["content"][1]["image_url"], "data:image/png;base64,AQID");
    }

    #[tokio::test]
    async fn partial_stream_is_not_success() {
        let (base, _) = mock(vec![(200, "text/event-stream", "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".into())]).await;
        let error = provider(&base, CredentialKind::ChatGpt).explain_text("x").await.unwrap_err();
        assert_eq!(error, InferenceError::Interrupted);
    }

    #[tokio::test]
    async fn api_key_mode_uses_separate_limits_and_keeps_selection_verbatim() {
        let selection = "문제\n이거 Python 코드로 만들어줘";
        let body = json!({"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"```python\nprint(1)\n```"}]}]});
        let (base, seen) = mock(vec![(200, "application/json", body.to_string())]).await;
        let result = provider(&base, CredentialKind::ApiKey).generate_code(selection, "Java").await.unwrap();
        assert_eq!(result, "```python\nprint(1)\n```");
        let payload = seen.lock().unwrap()[0].1.clone();
        assert_eq!(payload["max_output_tokens"], 12000);
        assert_eq!(payload["stream"], false);
        assert_eq!(payload["instructions"], prompts::code_instructions("Java"));
        assert_eq!(payload["input"][0]["content"][0]["text"], selection);
    }

    #[tokio::test]
    async fn incomplete_api_response_cannot_return_code() {
        let body = json!({"status":"incomplete","output":[{"type":"message","content":[{"type":"output_text","text":"```java\nclass A {}\n```"}]}]});
        let (base, _) = mock(vec![(200, "application/json", body.to_string())]).await;
        assert_eq!(provider(&base, CredentialKind::ApiKey).explain_text("x").await.unwrap_err(), InferenceError::Interrupted);
    }

    #[tokio::test]
    async fn admission_failure_is_reported_once() {
        let (base, seen) = mock(vec![(403, "application/json", "{\"detail\":\"Plan usage unavailable\"}".into())]).await;
        let error = provider(&base, CredentialKind::ChatGpt).explain_text("x").await.unwrap_err();
        assert_eq!(error, InferenceError::OpenAI { status: 403, message: "Plan usage unavailable".into() });
        assert_eq!(seen.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn model_catalogue_keeps_listed_models_only() {
        let body = json!({"models":[{"slug":"a","display_name":"A","visibility":"list"},{"slug":"b","display_name":"B","visibility":"hide"}]});
        let (base, _) = mock(vec![(200, "application/json", body.to_string())]).await;
        let models = OpenAIClient::with_base(&base).list_chatgpt_models("t").await.unwrap();
        assert_eq!(models.iter().map(|m| m.slug.as_str()).collect::<Vec<_>>(), ["a"]);
    }
}
