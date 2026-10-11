import { useEffect } from "react";
import { api, isMac, useResult, useSettingsView, useTrayMode, type ResultState } from "../lib/ipc";
import { displayAccelerator } from "../lib/shortcut";

const STATUS: Record<ResultState["status"], string> = {
  idle: "대기 중",
  selecting: "선택 중",
  analyzing: "설명 작성 중",
  ready: "완료",
  failed: "확인 필요",
};

export function TrayPopover() {
  const appMenu = useTrayMode();
  useEffect(() => {
    const close = (event: KeyboardEvent) => event.key === "Escape" && api.hideWindow();
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  }, []);
  if (appMenu === null) return null;
  if (!appMenu) return <FocusPopover />;
  return <AppPopover />;
}

function AppPopover() {
  const state = useResult();
  const view = useSettingsView();
  if (!state || !view) return null;

  const working = state.status === "selecting" || state.status === "analyzing";
  const shortcut = (key: keyof typeof view.settings.shortcuts) => displayAccelerator(view.settings.shortcuts[key], isMac);
  const run = (action: Parameters<typeof api.trayAction>[0]) => api.trayAction(action);

  return (
    <main className="tray-popover">
      <header className="tray-header">
        <strong>StudyLens</strong>
        <span>{state.billingLabel || "개인 학습"}</span>
      </header>

      <section className={`tray-status ${state.status}`}>
        <span className="moon-badge" aria-hidden="true"><Glyph name="moon" /></span>
        <div>
          <strong>{STATUS[state.status]}</strong>
          <small>{state.quickCopyMessage || state.progress?.stageTitle || "문제나 코드를 선택해 시작하세요"}</small>
        </div>
      </section>

      <section className="tray-actions">
        <Action icon="⌗" label="영역 캡처" detail="화면 문제를 설명" shortcut={shortcut("capture")} disabled={working} onClick={() => run("capture")} />
        <Action icon="T" label="선택 텍스트" detail="선택한 문제를 설명" shortcut={shortcut("text")} disabled={working} onClick={() => run("text")} />
        <Action icon="‹›" label="코드 바로 복사" detail={`${view.settings.codeLanguage} 코드만 클립보드로`} shortcut={shortcut("code")} disabled={working} onClick={() => run("code")} />
      </section>

      {working ? (
        <button className="tray-footer danger" onClick={() => run("cancel")}>현재 요청 취소</button>
      ) : (
        <>
          <button className="tray-footer" disabled={state.status !== "ready" && state.status !== "failed"} onClick={() => run("result")}>최근 결과 보기</button>
          <div className="tray-bottom">
            <button onClick={() => run("settings")}>StudyLens 설정…</button>
            <button onClick={() => run("quit")}>종료</button>
          </div>
        </>
      )}
    </main>
  );
}

function FocusPopover() {
  const open = () => api.trayAction("focus-settings");
  return (
    <main className="tray-popover focus-popover" aria-label="StudyLens 집중 모드 메뉴">
      <header className="focus-header"><strong>집중 모드</strong><span>StudyLens</span></header>
      <button className="focus-row focus-primary" onClick={open}>
        <span className="focus-circle active"><Glyph name="moon" /></span><strong>방해금지 모드</strong>
      </button>
      <section className="focus-duration">
        <button onClick={open}>1시간 동안</button>
        <button onClick={open}>오늘 저녁까지</button>
      </section>
      <section className="focus-modes">
        <button className="focus-row" onClick={open}><span className="focus-circle"><Glyph name="person" /></span><strong>개인 시간</strong></button>
        <button className="focus-row" onClick={open}><span className="focus-circle"><Glyph name="work" /></span><strong>업무</strong></button>
        <button className="focus-row" onClick={open}><span className="focus-circle"><Glyph name="bed" /></span><strong>수면</strong></button>
        <button className="focus-row" onClick={open}><span className="focus-circle"><Glyph name="reduce" /></span><strong>방해 요소 줄이기</strong></button>
      </section>
      <button className="focus-settings" onClick={open}>집중 모드 설정…</button>
    </main>
  );
}

function Glyph({ name }: { name: "moon" | "person" | "work" | "bed" | "reduce" }) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" fill="currentColor">
      {name === "moon" && <path d="M9.4 1.7a10.5 10.5 0 1 0 12.9 12.9A9 9 0 0 1 9.4 1.7Z" />}
      {name === "person" && <><circle cx="12" cy="7.2" r="4" /><path d="M3 21c0-5 3.7-8 9-8s9 3 9 8Z" /></>}
      {name === "work" && <><rect x="4" y="1" width="16" height="22" rx="3" /><rect x="8" y="3" width="8" height="2" rx="1" fill="var(--focus-icon-bg)" /><circle cx="12" cy="11" r="3" fill="var(--focus-icon-bg)" /><path d="M7 19c0-3 2-5 5-5s5 2 5 5Z" fill="var(--focus-icon-bg)" /></>}
      {name === "bed" && <><rect x="1" y="10" width="22" height="9" rx="2" /><path d="M2 6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v3H2Z" /><path d="M2 18h3v4H2Zm17 0h3v4h-3Z" /><path d="M5 6h5v2H5Zm9 0h5v2h-5Z" fill="var(--focus-icon-bg)" /></>}
      {name === "reduce" && <g fill="none" stroke="currentColor" strokeWidth="1.6"><ellipse cx="12" cy="12" rx="10" ry="4.7" /><ellipse cx="12" cy="12" rx="10" ry="4.7" transform="rotate(60 12 12)" /><ellipse cx="12" cy="12" rx="10" ry="4.7" transform="rotate(120 12 12)" /></g>}
    </svg>
  );
}

function Action({ icon, label, detail, shortcut, disabled, onClick }: { icon: string; label: string; detail: string; shortcut: string; disabled: boolean; onClick: () => void }) {
  return (
    <button className="tray-action" disabled={disabled} onClick={onClick}>
      <span className="action-icon">{icon}</span>
      <span className="action-copy"><strong>{label}</strong><small>{detail}</small></span>
      <kbd>{shortcut}</kbd>
    </button>
  );
}
