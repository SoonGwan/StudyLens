import { useEffect, useState } from "react";
import { api, isMac, useResult, useSettingsView, type Block, type Hint, type RequestProgress, type ResultState } from "../lib/ipc";
import { Prose } from "../lib/Prose";
import { displayAccelerator } from "../lib/shortcut";

const STATUS_TEXT: Record<ResultState["status"], string> = {
  idle: "대기 중",
  selecting: "선택 중",
  analyzing: "설명 작성 중",
  ready: "완료",
  failed: "확인 필요",
};

export function ResultWindow() {
  const state = useResult();
  const view = useSettingsView();
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") api.hideWindow();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  if (!state) return null;
  const working = state.status === "selecting" || state.status === "analyzing";
  const codeBlocks = state.blocks.filter((b) => b.language !== null);
  const single = codeBlocks.length === 1 ? codeBlocks[0] : null;
  const shortcut = view ? displayAccelerator(view.settings.shortcuts.capture, isMac) : "";

  return (
    <div className="window">
      <header className="titlebar" data-tauri-drag-region>
        <span className={`dot ${state.status}`} />
        <h1 data-tauri-drag-region>{STATUS_TEXT[state.status]}</h1>
        {state.billingLabel && <span className="faint" data-tauri-drag-region>· {state.billingLabel}</span>}
        <div className="spacer" data-tauri-drag-region />
        {working && (
          <button className="btn small" onClick={() => api.cancel()}>
            취소
          </button>
        )}
      </header>

      <main className="content">
        {state.progress && <ProgressLine progress={state.progress} />}
        {state.quickCopyMessage && !working && <p className="notice">{state.quickCopyMessage}</p>}
        {state.capturedImage && <Capture src={state.capturedImage} />}
        {state.selectedText && <Selection text={state.selectedText} />}
        {state.errorMessage && <ErrorCard message={state.errorMessage} hint={state.hint} />}
        {state.status === "analyzing" && !state.explanation && <Thinking />}
        {state.explanation && <Answer blocks={state.blocks} copiedId={state.copiedCodeId} />}
        {state.status === "idle" && !state.explanation && !state.errorMessage && <Empty shortcut={shortcut} />}
      </main>

      <footer className="footer">
        <button className="btn" disabled={working} onClick={() => api.start("capture")}>
          새로 캡처 <kbd>{shortcut}</kbd>
        </button>
        <div className="spacer" />
        <button className={`btn ${state.copied ? "done" : ""}`} disabled={working || !state.explanation} onClick={() => api.copyExplanation()}>
          {state.copied ? "✓ 복사됨" : "전체 복사"}
        </button>
        {single && (
          <button
            className={`btn primary ${state.copiedCodeId === single.id ? "done-primary" : ""}`}
            disabled={working || !single.isComplete || !single.text.trim()}
            onClick={() => api.copyCode(single.id)}
          >
            {state.copiedCodeId === single.id ? "✓ 코드 복사됨" : "코드만 복사"}
          </button>
        )}
      </footer>
    </div>
  );
}

function Capture({ src }: { src: string }) {
  const [open, setOpen] = useState(false);
  return (
    <button className={`capture card ${open ? "open" : ""}`} onClick={() => setOpen(!open)} title={open ? "접기" : "크게 보기"}>
      <img src={src} alt="선택한 화면 영역" />
    </button>
  );
}

function Selection({ text }: { text: string }) {
  const [open, setOpen] = useState(false);
  const long = text.length > 280 || text.split("\n").length > 5;
  return (
    <section className="selection card">
      <div className="label">선택한 텍스트</div>
      <div className={`selectable ${open || !long ? "" : "clamped"}`}>{text}</div>
      {long && (
        <button className="btn ghost small" onClick={() => setOpen(!open)}>
          {open ? "접기" : "더 보기"}
        </button>
      )}
    </section>
  );
}

function ProgressLine({ progress }: { progress: RequestProgress }) {
  const [now, setNow] = useState(Date.now());
  const running = progress.endedAtMs === null;
  useEffect(() => {
    if (!running) return;
    const timer = setInterval(() => setNow(Date.now()), 200);
    return () => clearInterval(timer);
  }, [running]);
  const elapsed = ((progress.endedAtMs ?? now) - progress.startedAtMs) / 1000;
  return (
    <details className="progress">
      <summary>
        <span>{progress.stageTitle}</span>
        <span className="faint tabular">{elapsed.toFixed(1)}초</span>
      </summary>
      <pre className="selectable">{progress.diagnostics}</pre>
    </details>
  );
}

const HINTS: Record<Exclude<Hint, "input">, { label: string; action: () => void }> = {
  accessibility: { label: "손쉬운 사용 설정 열기", action: () => api.openPrivacySettings("accessibility") },
  screenRecording: { label: "화면 기록 설정 열기", action: () => api.openPrivacySettings("screen") },
  chatGptUsage: { label: "ChatGPT 사용량 보기", action: () => api.openLink("https://chatgpt.com/settings/usage") },
  claudeUsage: { label: "Claude 사용량 보기", action: () => api.openLink("https://claude.ai/settings/usage") },
  settings: { label: "설정 열기", action: () => api.openSettings() },
};

function ErrorCard({ message, hint }: { message: string; hint: Hint | null }) {
  return (
    <section className="error card">
      <div className="selectable">{message}</div>
      {hint === "input" && <div className="faint">입력·권한을 확인해 주세요. 이 오류는 로그인·사용량 문제가 아닙니다.</div>}
      {hint && hint !== "input" && (
        <button className="btn small" onClick={HINTS[hint].action}>
          {HINTS[hint].label}
        </button>
      )}
    </section>
  );
}

function Thinking() {
  return (
    <section className="thinking" aria-live="polite">
      <div className="shimmer" style={{ width: "72%" }} />
      <div className="shimmer" style={{ width: "94%" }} />
      <div className="shimmer" style={{ width: "58%" }} />
      <p className="faint">문제를 읽고 설명을 쓰고 있어요…</p>
    </section>
  );
}

function Answer({ blocks, copiedId }: { blocks: Block[]; copiedId: number | null }) {
  return (
    <article className="answer">
      {blocks.map((block) =>
        block.language === null ? <Prose key={block.id} text={block.text} /> : <Code key={block.id} block={block} copied={copiedId === block.id} />,
      )}
    </article>
  );
}

function Code({ block, copied }: { block: Block; copied: boolean }) {
  return (
    <section className="code card">
      <div className="code-head">
        <span>{block.language || "코드"}</span>
        <div className="spacer" />
        {!block.isComplete && <span className="faint">작성 중단됨</span>}
        <button className={`btn ghost small ${copied ? "done" : ""}`} disabled={!block.isComplete || !block.text.trim()} onClick={() => api.copyCode(block.id)}>
          {copied ? "✓ 복사됨" : "복사"}
        </button>
      </div>
      <pre className="selectable">{block.text}</pre>
    </section>
  );
}

function Empty({ shortcut }: { shortcut: string }) {
  return (
    <section className="empty">
      <img src="/mascot.png" alt="" width={72} height={72} />
      <p>아직 결과가 없어요</p>
      <p className="faint">{shortcut}로 화면 영역을 선택하거나, 텍스트를 드래그한 뒤 단축키를 눌러 보세요.</p>
    </section>
  );
}
