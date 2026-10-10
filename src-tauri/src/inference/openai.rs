//! OpenAI Responses API, used with either a ChatGPT plan token (streamed, no output cap)
//! or a separately billed API key.

use super::sse::{EventFramer, ResponseAccumulator};
use super::{capabilities, prompts, InferenceError, InferenceProvider, Progress, ProgressFn};
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

    /// Both connections request a stream. A compatible transport may still answer with one
    /// JSON body; then it must report `completed` and no SSE timings are recorded.
    async fn respond(&self, credential: &Credential, payload: Value, progress: Option<&ProgressFn>) -> Result<String, InferenceError> {
        let notify = |event| {
            if let Some(progress) = progress {
                progress(event);
            }
        };
        let response = self
            .http
            .post(format!("{}/responses", self.base))
            .bearer_auth(&credential.token)
            .header("Accept", "text/event-stream")
            .timeout(Duration::from_secs(300))
            .json(&payload)
            .send()
            .await?;
        let status = response.status().as_u16();
        if !(200..300).contains(&status) {
            let body = response.bytes().await.unwrap_or_default();
            let body = &body[..body.len().min(65_536)];
            return Err(api_error(status, &serde_json::from_slice(body).unwrap_or(Value::Null)));
        }
        let is_stream = response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.to_ascii_lowercase().contains("text/event-stream"));
        if is_stream {
            let mut framer = EventFramer::default();
            let mut accumulator = ResponseAccumulator::default();
            let mut reporter = ProgressReporter::default();
            let mut bytes = response.bytes_stream();
            let mut pending = Vec::new();
            loop {
                let chunk = bytes.next().await;
                let events = match &chunk {
                    Some(chunk) => framer.push(chunk.as_ref().map_err(|e| InferenceError::Network(e.to_string()))?)?,
                    None => framer.finish()?.into_iter().collect(),
                };
                pending.extend(events);
                for event in pending.drain(..) {
                    reporter.observe(&event, None, &notify);
                    let completed = accumulator.consume(&event)?;
                    reporter.observe(&event, completed.as_deref(), &notify);
                    if let Some(text) = completed {
                        return Ok(text);
                    }
                }
                if chunk.is_none() {
                    return Err(InferenceError::Interrupted);
                }
            }
        }
        let body = response.bytes().await?;
        if body.len() > 20 * 1024 * 1024 {
            return Err(InferenceError::InvalidResponse);
        }
        let body: Value = serde_json::from_slice(&body).map_err(|_| InferenceError::InvalidResponse)?;
        if body["status"] != "completed" {
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
        notify(Progress::FirstText);
        notify(Progress::Completed);
        Ok(text.to_string())
    }
}

/// Turns stream events into first-event / first-text / completed milestones.
#[derive(Default)]
struct ProgressReporter {
    saw_event: bool,
    saw_text: bool,
}

impl ProgressReporter {
    fn observe(&mut self, event: &str, completed: Option<&str>, notify: &impl Fn(Progress)) {
        let Ok(value) = serde_json::from_str::<Value>(event) else { return };
        let Some(kind) = value["type"].as_str() else { return };
        if !self.saw_event {
            self.saw_event = true;
            notify(Progress::FirstEvent);
        }
        let delta = matches!(kind, "response.output_text.delta" | "response.refusal.delta") && value["delta"].as_str().is_some_and(|d| !d.is_empty());
        if !self.saw_text && (delta || completed.is_some_and(|t| !t.is_empty())) {
            self.saw_text = true;
            notify(Progress::FirstText);
        }
        if completed.is_some() {
            notify(Progress::Completed);
        }
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
    /// Requested effort; only sent when the model is known to accept it.
    pub effort: String,
    /// Picture region attached to text and code requests.
    pub image: Option<Vec<u8>>,
    pub additional_instructions: String,
    pub progress: Option<ProgressFn>,
}

impl OpenAIProvider {
    pub fn new(client: OpenAIClient, credential: Credential, model: String) -> Self {
        Self { client, credential, model, effort: capabilities::MODEL_DEFAULT.into(), image: None, additional_instructions: String::new(), progress: None }
    }

    fn payload(&self, instructions: &str, content: Vec<Value>, api_key_limit: u32) -> Result<Value, InferenceError> {
        let model = self.model.trim();
        if model.is_empty() {
            return Err(InferenceError::InvalidModel);
        }
        let mut payload = json!({
            "model": model,
            "instructions": instructions,
            "input": [{ "role": "user", "content": content }],
            "store": false,
            "stream": true,
        });
        if self.credential.kind == CredentialKind::ApiKey {
            payload["max_output_tokens"] = json!(api_key_limit);
        }
        if let Some(effort) = capabilities::validated_effort(&self.effort, model) {
            payload["reasoning"] = json!({ "effort": effort });
        }
        Ok(payload)
    }

    /// The selection, optional extra instructions, then the optional picture: one user message.
    fn selection_content(&self, text: &str) -> Result<Vec<Value>, InferenceError> {
        capabilities::validate_text(text, &self.additional_instructions)?;
        let mut content = vec![json!({ "type": "input_text", "text": text })];
        if !self.additional_instructions.trim().is_empty() {
            content.push(json!({ "type": "input_text", "text": format!("추가 지시:\n{}", self.additional_instructions) }));
        }
        if let Some(image) = &self.image {
            capabilities::validate_image(image, self.model.trim())?;
            content.push(image_part(image));
        }
        Ok(content)
    }
}

fn image_part(png: &[u8]) -> Value {
    let url = format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(png));
    json!({ "type": "input_image", "image_url": url, "detail": "high" })
}

#[async_trait]
impl InferenceProvider for OpenAIProvider {
    async fn explain_image(&self, png: &[u8]) -> Result<String, InferenceError> {
        capabilities::validate_image(png, self.model.trim())?;
        let content = vec![json!({ "type": "input_text", "text": prompts::IMAGE_REQUEST }), image_part(png)];
        let payload = self.payload(prompts::INSTRUCTIONS, content, 2200)?;
        self.client.respond(&self.credential, payload, self.progress.as_ref()).await
    }

    async fn explain_text(&self, text: &str) -> Result<String, InferenceError> {
        let payload = self.payload(prompts::INSTRUCTIONS, self.selection_content(text)?, 2200)?;
        self.client.respond(&self.credential, payload, self.progress.as_ref()).await
    }

    async fn generate_code(&self, text: &str, language: &str) -> Result<String, InferenceError> {
        let payload = self.payload(&prompts::code_instructions(language), self.selection_content(text)?, 12_000)?;
        self.client.respond(&self.credential, payload, self.progress.as_ref()).await
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::inference::capabilities::InputError;
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
        OpenAIProvider::new(OpenAIClient::with_base(base), Credential { token: "test-token".into(), kind }, "gpt-4.1-mini".into())
    }

    fn png() -> Vec<u8> {
        let mut png = Vec::new();
        image::DynamicImage::new_rgba8(2, 2).write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        png
    }

    const STREAM: &str = "event: x\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"단계별 \"}\n\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"설명\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";

    #[tokio::test]
    async fn plan_image_request_streams_until_completed_event_and_reports_progress() {
        let (base, seen) = mock(vec![(200, "text/event-stream", STREAM.into())]).await;
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut provider = provider(&base, CredentialKind::ChatGpt);
        let record = events.clone();
        provider.progress = Some(Arc::new(move |e| record.lock().unwrap().push(e)));
        let image = png();
        assert_eq!(provider.explain_image(&image).await.unwrap(), "단계별 설명");
        let (head, payload) = seen.lock().unwrap()[0].clone();
        assert!(head.to_ascii_lowercase().contains("authorization: bearer test-token"));
        assert_eq!(payload["stream"], true);
        assert_eq!(payload["store"], false);
        assert!(payload.get("max_output_tokens").is_none());
        assert!(payload["input"][0]["content"][1]["image_url"].as_str().unwrap().starts_with("data:image/png;base64,"));
        assert_eq!(*events.lock().unwrap(), [Progress::FirstEvent, Progress::FirstText, Progress::Completed]);
    }

    #[tokio::test]
    async fn partial_stream_is_not_success() {
        let (base, _) = mock(vec![(200, "text/event-stream", "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".into())]).await;
        let error = provider(&base, CredentialKind::ChatGpt).explain_text("x").await.unwrap_err();
        assert_eq!(error, InferenceError::Interrupted);
    }

    #[tokio::test]
    async fn api_key_mode_streams_with_separate_limits_and_keeps_selection_verbatim() {
        let selection = "문제\n이거 Python 코드로 만들어줘";
        let (base, seen) = mock(vec![(200, "text/event-stream", STREAM.into())]).await;
        provider(&base, CredentialKind::ApiKey).generate_code(selection, "Java").await.unwrap();
        let payload = seen.lock().unwrap()[0].1.clone();
        assert_eq!(payload["max_output_tokens"], 12000);
        assert_eq!(payload["stream"], true);
        assert_eq!(payload["instructions"], prompts::code_instructions("Java"));
        assert_eq!(payload["input"][0]["content"][0]["text"], selection);
        assert_eq!(payload["input"][0]["content"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn json_answer_to_a_stream_request_must_be_completed() {
        let body = json!({"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"```python\nprint(1)\n```"}]}]});
        let (base, _) = mock(vec![(200, "application/json", body.to_string())]).await;
        assert_eq!(provider(&base, CredentialKind::ApiKey).explain_text("x").await.unwrap(), "```python\nprint(1)\n```");
        let body = json!({"status":"incomplete","output":[{"type":"message","content":[{"type":"output_text","text":"```java\nclass A {}\n```"}]}]});
        let (base, _) = mock(vec![(200, "application/json", body.to_string())]).await;
        assert_eq!(provider(&base, CredentialKind::ApiKey).explain_text("x").await.unwrap_err(), InferenceError::Interrupted);
    }

    #[tokio::test]
    async fn reasoning_effort_is_sent_only_when_the_model_accepts_it() {
        for (model, effort, expected) in [("gpt-5.1", "medium", Some("medium")), ("gpt-6.1-sol", "high", Some("high")), ("gpt-5.1", "modelDefault", None), ("gpt-4.1-mini", "low", None)] {
            for kind in [CredentialKind::ChatGpt, CredentialKind::ApiKey] {
                let (base, seen) = mock(vec![(200, "text/event-stream", STREAM.into())]).await;
                let mut provider = provider(&base, kind);
                provider.model = model.into();
                provider.effort = effort.into();
                provider.explain_text("문제").await.unwrap();
                let payload = seen.lock().unwrap()[0].1.clone();
                assert_eq!(payload["reasoning"]["effort"].as_str(), expected, "{model} {effort}");
            }
        }
    }

    #[tokio::test]
    async fn selection_instructions_and_picture_form_one_user_message() {
        let (base, seen) = mock(vec![(200, "text/event-stream", STREAM.into())]).await;
        let mut provider = provider(&base, CredentialKind::ChatGpt);
        provider.additional_instructions = "Java로".into();
        provider.image = Some(png());
        provider.explain_text("문제 ex1.png").await.unwrap();
        let content = seen.lock().unwrap()[0].1["input"][0]["content"].clone();
        assert_eq!(content[0]["text"], "문제 ex1.png");
        assert_eq!(content[1]["text"], "추가 지시:\nJava로");
        assert_eq!(content[2]["type"], "input_image");
    }

    #[tokio::test]
    async fn invalid_inputs_are_blocked_before_the_network() {
        let unreachable = "http://127.0.0.1:9";
        let mut unknown = provider(unreachable, CredentialKind::ApiKey);
        unknown.model = "custom-model".into();
        unknown.image = Some(png());
        assert!(matches!(unknown.explain_text("문제").await, Err(InferenceError::Input(InputError::UnsupportedImageModel))));
        let mut long = provider(unreachable, CredentialKind::ApiKey);
        long.additional_instructions = "a".repeat(2001);
        assert!(matches!(long.explain_text("문제").await, Err(InferenceError::Input(InputError::InstructionsTooLong))));
        assert!(matches!(provider(unreachable, CredentialKind::ApiKey).explain_image(b"nope").await, Err(InferenceError::Input(InputError::InvalidImage))));
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
