//! Server-sent events for the OpenAI Responses stream. Raw bytes are framed by hand so
//! empty-line frame boundaries, CRLF and UTF-8 split across chunks all survive.

use super::InferenceError;
use serde_json::Value;

const MAX_FRAME: usize = 2 * 1024 * 1024;

#[derive(Default)]
pub struct EventFramer {
    line: Vec<u8>,
    fields: Vec<String>,
    previous_cr: bool,
    frame_size: usize,
}

impl EventFramer {
    /// Returns every event completed by `chunk`.
    pub fn push(&mut self, chunk: &[u8]) -> Result<Vec<String>, InferenceError> {
        let mut events = Vec::new();
        for &byte in chunk {
            if self.previous_cr {
                self.previous_cr = false;
                if byte == b'\n' {
                    continue;
                }
            }
            if byte == b'\n' || byte == b'\r' {
                self.previous_cr = byte == b'\r';
                if let Some(event) = self.end_line()? {
                    events.push(event);
                }
                continue;
            }
            if self.line.len() >= MAX_FRAME {
                return Err(InferenceError::InvalidResponse);
            }
            self.line.push(byte);
        }
        Ok(events)
    }

    pub fn finish(&mut self) -> Result<Option<String>, InferenceError> {
        if !self.line.is_empty() {
            self.end_line()?;
        }
        Ok(self.take_event())
    }

    fn end_line(&mut self) -> Result<Option<String>, InferenceError> {
        if self.line.is_empty() {
            return Ok(self.take_event());
        }
        let line = String::from_utf8_lossy(&std::mem::take(&mut self.line)).into_owned();
        if let Some(data) = line.strip_prefix("data:") {
            let data = data.strip_prefix(' ').unwrap_or(data);
            self.frame_size += data.len();
            if self.frame_size > MAX_FRAME {
                return Err(InferenceError::InvalidResponse);
            }
            self.fields.push(data.to_string());
        }
        Ok(None)
    }

    fn take_event(&mut self) -> Option<String> {
        if self.fields.is_empty() {
            return None;
        }
        self.frame_size = 0;
        Some(std::mem::take(&mut self.fields).join("\n"))
    }
}

/// Partial output is not success: only the terminal completion event yields a result.
#[derive(Default)]
pub struct ResponseAccumulator {
    text: String,
}

impl ResponseAccumulator {
    pub fn consume(&mut self, event: &str) -> Result<Option<String>, InferenceError> {
        if event == "[DONE]" {
            return Ok(None);
        }
        let value: Value = serde_json::from_str(event).map_err(|_| InferenceError::InvalidResponse)?;
        let kind = value["type"].as_str().ok_or(InferenceError::InvalidResponse)?;
        match kind {
            "response.output_text.delta" | "response.refusal.delta" => {
                self.text.push_str(value["delta"].as_str().unwrap_or_default());
            }
            "response.completed" => {
                let response = &value["response"];
                if response["status"].as_str() != Some("completed") {
                    return Err(InferenceError::Interrupted);
                }
                if self.text.is_empty() {
                    self.text = response["output"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .flat_map(|item| item["content"].as_array().cloned().unwrap_or_default())
                        .filter_map(|c| c["text"].as_str().or(c["refusal"].as_str()).map(str::to_string))
                        .collect::<Vec<_>>()
                        .join("\n");
                }
                let result = self.text.trim();
                if result.is_empty() {
                    return Err(InferenceError::EmptyOutput);
                }
                return Ok(Some(result.to_string()));
            }
            "response.failed" | "error" => {
                let error = value["response"]["error"].as_object().or(value["error"].as_object()).cloned();
                let error = error.map(Value::Object).unwrap_or(value.clone());
                let code = error["code"].as_str().map(str::to_string);
                let status = if code.as_deref() == Some("subscription_sharing_usage_limit_exceeded") { 429 } else { 503 };
                return Err(super::openai::api_error(status, &serde_json::json!({ "error": error })));
            }
            "response.incomplete" => return Err(InferenceError::Interrupted),
            _ => {}
        }
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_preserve_crlf_multiline_data_and_utf8() {
        let mut framer = EventFramer::default();
        let body = ": keepalive\r\ndata: 첫 줄\r\ndata: 둘째 줄\r\n\r\ndata: final\n\n".as_bytes();
        let mut events = Vec::new();
        // Split inside a multi-byte character to prove chunk boundaries don't matter.
        for chunk in body.chunks(5) {
            events.extend(framer.push(chunk).unwrap());
        }
        assert_eq!(events, ["첫 줄\n둘째 줄", "final"]);
        assert_eq!(framer.finish().unwrap(), None);
    }

    #[test]
    fn completed_stream_returns_accumulated_text() {
        let mut acc = ResponseAccumulator::default();
        assert_eq!(acc.consume(r#"{"type":"response.output_text.delta","delta":"단계별 "}"#).unwrap(), None);
        acc.consume(r#"{"type":"response.output_text.delta","delta":"설명"}"#).unwrap();
        let done = acc.consume(r#"{"type":"response.completed","response":{"status":"completed"}}"#).unwrap();
        assert_eq!(done.as_deref(), Some("단계별 설명"));
    }

    #[test]
    fn failure_events_map_usage_limit() {
        let mut acc = ResponseAccumulator::default();
        let error = acc
            .consume(r#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"x"}}}"#)
            .unwrap_err();
        assert!(matches!(error, InferenceError::OpenAI { status: 429, .. }), "{error:?}");
    }

    #[test]
    fn incomplete_is_not_success() {
        let mut acc = ResponseAccumulator::default();
        assert_eq!(acc.consume(r#"{"type":"response.incomplete"}"#).unwrap_err(), InferenceError::Interrupted);
    }
}
