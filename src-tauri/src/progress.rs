//! In-memory request timings shown in the result window. No input, output or credentials.

use crate::inference::Progress;
use serde::Serialize;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Stage {
    ReadingSelection,
    SelectingImage,
    PreparingConnection,
    Waiting,
    Generating,
    Copying,
    Completed,
    Cancelled,
    Failed,
}

impl Stage {
    pub fn title(self) -> &'static str {
        match self {
            Stage::ReadingSelection => "선택 텍스트 읽는 중",
            Stage::SelectingImage => "그림 영역 선택 중",
            Stage::PreparingConnection => "연결 준비 중",
            Stage::Waiting => "응답 대기 중",
            Stage::Generating => "응답 작성 중",
            Stage::Copying => "코드 복사 중",
            Stage::Completed => "완료",
            Stage::Cancelled => "취소됨",
            Stage::Failed => "실패",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestProgress {
    pub stage: Stage,
    pub stage_title: &'static str,
    /// Wall-clock start (ms since epoch) so the window can tick the elapsed time.
    pub started_at_ms: u64,
    pub ended_at_ms: Option<u64>,
    pub diagnostics: String,
    #[serde(skip)]
    started: Option<Instant>,
    #[serde(skip)]
    connection_started: Option<Instant>,
    #[serde(skip)]
    summary: String,
    #[serde(skip)]
    timings: Timings,
}

/// Selection and connection are durations; the rest are measured from the start.
#[derive(Debug, Clone, Default)]
struct Timings {
    selection: Option<f64>,
    connection: Option<f64>,
    first_event: Option<f64>,
    first_text: Option<f64>,
    completed: Option<f64>,
}

fn epoch_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or_default()
}

impl RequestProgress {
    pub fn new(stage: Stage, model: &str, mode_title: &str, effort: Option<&str>) -> Self {
        let model = if model.is_empty() { "기본 모델" } else { model };
        let mut progress = Self {
            stage,
            stage_title: stage.title(),
            started_at_ms: epoch_ms(),
            ended_at_ms: None,
            diagnostics: String::new(),
            started: Some(Instant::now()),
            connection_started: None,
            summary: format!("모델: {model} · 강도: {} · {mode_title}", effort.unwrap_or("모델 기본값")),
            timings: Timings::default(),
        };
        progress.refresh();
        progress
    }

    fn since_start(&self) -> f64 {
        self.started.map(|s| s.elapsed().as_secs_f64()).unwrap_or_default()
    }

    pub fn set_stage(&mut self, stage: Stage) {
        if self.ended_at_ms.is_none() {
            self.stage = stage;
            self.refresh();
        }
    }

    pub fn finish_selection(&mut self) {
        self.timings.selection = Some(self.since_start());
        self.refresh();
    }

    pub fn prepare_connection(&mut self) {
        self.connection_started = Some(Instant::now());
        self.set_stage(Stage::PreparingConnection);
    }

    pub fn wait_for_response(&mut self) {
        self.timings.connection = self.connection_started.map(|s| s.elapsed().as_secs_f64());
        self.set_stage(Stage::Waiting);
    }

    pub fn record(&mut self, event: Progress) {
        let elapsed = self.since_start();
        match event {
            Progress::FirstEvent => {
                self.timings.first_event.get_or_insert(elapsed);
            }
            Progress::FirstText => {
                self.timings.first_text.get_or_insert(elapsed);
                self.set_stage(Stage::Generating);
            }
            Progress::Completed => {
                self.timings.completed.get_or_insert(elapsed);
            }
        }
        self.refresh();
    }

    pub fn finish(&mut self, stage: Stage) {
        if self.ended_at_ms.is_none() {
            self.stage = stage;
            self.ended_at_ms = Some(epoch_ms());
            self.refresh();
        }
    }

    fn refresh(&mut self) {
        self.stage_title = self.stage.title();
        let mut lines = vec![self.summary.clone()];
        let t = &self.timings;
        for (label, value) in [
            ("선택 읽기", t.selection),
            ("인증·모델 확인", t.connection),
            ("첫 SSE 이벤트 (시작 후)", t.first_event),
            ("첫 출력 (시작 후)", t.first_text),
            ("응답 완료 (시작 후)", t.completed),
        ] {
            if let Some(value) = value {
                lines.push(format!("{label}: {value:.2}초"));
            }
        }
        self.diagnostics = lines.join("\n");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stages_and_timings_progress_in_order() {
        let mut progress = RequestProgress::new(Stage::ReadingSelection, "gpt-5.1", "ChatGPT 구독", Some("low"));
        progress.finish_selection();
        progress.prepare_connection();
        assert_eq!(progress.stage, Stage::PreparingConnection);
        progress.wait_for_response();
        progress.record(Progress::FirstEvent);
        progress.record(Progress::FirstText);
        assert_eq!(progress.stage, Stage::Generating);
        progress.record(Progress::Completed);
        progress.finish(Stage::Completed);
        assert!(progress.ended_at_ms.is_some());
        for label in ["강도: low", "선택 읽기", "인증·모델 확인", "첫 SSE 이벤트", "첫 출력", "응답 완료"] {
            assert!(progress.diagnostics.contains(label), "{label}");
        }
        progress.set_stage(Stage::Waiting);
        assert_eq!(progress.stage, Stage::Completed, "finished requests don't move");
    }
}
