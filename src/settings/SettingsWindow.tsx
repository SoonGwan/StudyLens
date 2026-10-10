import { useEffect, useState, type ReactNode } from "react";
import { api, isMac, useSettingsView, type BillingMode, type Settings, type SettingsView, type Shortcuts } from "../lib/ipc";
import { acceleratorFromEvent, displayAccelerator } from "../lib/shortcut";

const MODES: { id: BillingMode; title: string; detail: string }[] = [
  { id: "claudeCode", title: "Claude", detail: "Claude Code 구독" },
  { id: "chatGpt", title: "ChatGPT", detail: "ChatGPT 구독" },
  { id: "apiKey", title: "API 키", detail: "OpenAI 별도 결제" },
];

export function SettingsWindow() {
  const view = useSettingsView();
  const [error, setError] = useState<string | null>(null);
  if (!view) return null;
  const s = view.settings;
  const save = (patch: Partial<Settings>) => {
    setError(null);
    api.saveSettings({ ...s, ...patch }).catch((e) => setError(String(e)));
  };

  return (
    <div className="settings">
      <header className="titlebar" data-tauri-drag-region>
        <h1 data-tauri-drag-region>설정</h1>
      </header>
      <main className="sections">
        {!s.onboarded && <Welcome view={view} onDone={() => save({ onboarded: true })} />}

        <Section title="AI 연결" note="답변을 만들 AI와 사용량을 고르세요.">
          <div className="segmented" role="tablist">
            {MODES.map((mode) => (
              <button
                key={mode.id}
                role="tab"
                aria-selected={s.billingMode === mode.id}
                className={s.billingMode === mode.id ? "on" : ""}
                disabled={view.working || view.connection.busy}
                onClick={() => save({ billingMode: mode.id })}
              >
                <strong>{mode.title}</strong>
                <span>{mode.detail}</span>
              </button>
            ))}
          </div>
          {s.billingMode === "claudeCode" && <ClaudePanel view={view} save={save} />}
          {s.billingMode === "chatGpt" && <ChatGptPanel view={view} save={save} />}
          {s.billingMode === "apiKey" && <ApiKeyPanel view={view} save={save} />}
          {view.connection.message && <p className="message selectable">{view.connection.message}</p>}
        </Section>

        <Section title="단축키" note="Command·Control·Option 중 하나를 포함해야 합니다.">
          <ShortcutRow name="영역 캡처" field="capture" view={view} save={save} />
          <ShortcutRow name="선택 텍스트 설명" field="text" view={view} save={save} />
          <ShortcutRow name="코드 바로 복사" field="code" view={view} save={save} />
          {view.shortcutErrors.map((e) => (
            <p key={e} className="message error-text">{e}</p>
          ))}
          {error && <p className="message error-text">{error}</p>}
        </Section>

        <Section title="코드 바로 복사" note="결과 창 없이 코드만 클립보드에 넣습니다. 본문에 언어를 적으면 그 언어를 우선합니다.">
          <Row label="기본 언어">
            <select value={s.codeLanguage} onChange={(e) => save({ codeLanguage: e.target.value })}>
              {view.codeLanguages.map((l) => (
                <option key={l}>{l}</option>
              ))}
            </select>
          </Row>
        </Section>

        {view.platform === "macos" && (
          <Section title="권한" note="macOS가 처음 사용할 때 묻습니다. 거절했다면 여기서 다시 허용하세요.">
            <Row label="화면 기록" detail="영역 캡처">
              <button className="btn small" onClick={() => api.openPrivacySettings("screen")}>열기</button>
            </Row>
            <Row label="손쉬운 사용" detail="선택 텍스트 읽기">
              <button className="btn small" onClick={() => api.openPrivacySettings("accessibility")}>열기</button>
            </Row>
          </Section>
        )}

        <p className="footnote">
          StudyLens는 개인 학습용입니다. 진행 중인 시험·감독 환경에서는 정답 대신 개념 복습만 안내하며, 창 숨기기·위장·자동 입력 기능은 없습니다.
        </p>
      </main>
    </div>
  );
}

type Save = (patch: Partial<Settings>) => void;

function Section({ title, note, children }: { title: string; note?: string; children: ReactNode }) {
  return (
    <section className="section">
      <h2>{title}</h2>
      {note && <p className="note">{note}</p>}
      <div className="card group">{children}</div>
    </section>
  );
}

function Row({ label, detail, children }: { label: string; detail?: string; children: ReactNode }) {
  return (
    <div className="row">
      <div className="row-label">
        <span>{label}</span>
        {detail && <small>{detail}</small>}
      </div>
      <div className="row-control">{children}</div>
    </div>
  );
}

function Welcome({ view, onDone }: { view: SettingsView; onDone: () => void }) {
  const k = view.settings.shortcuts;
  const show = (a: string) => displayAccelerator(a, isMac);
  return (
    <section className="welcome card">
      <img src="/mascot.png" alt="" width={56} height={56} />
      <div>
        <h2>StudyLens에 오신 걸 환영해요</h2>
        <p>
          {isMac ? "메뉴바" : "작업 표시줄 트레이"}의 작은 점 아이콘에서 실행돼요. 평소에는 숨어 있다가 단축키를 누를 때만 나타납니다.
        </p>
        <ul>
          <li><kbd>{show(k.capture)}</kbd> 화면 영역을 선택해 설명 받기</li>
          <li><kbd>{show(k.text)}</kbd> 드래그한 텍스트 설명 받기</li>
          <li><kbd>{show(k.code)}</kbd> 드래그한 문제의 코드만 바로 복사</li>
        </ul>
        <button className="btn primary" onClick={onDone}>시작하기</button>
      </div>
    </section>
  );
}

function ClaudePanel({ view, save }: { view: SettingsView; save: Save }) {
  const { busy, claudeStatus } = view.connection;
  const [path, setPath] = useState(view.settings.claudePath);
  useEffect(() => {
    if (!claudeStatus) api.claudeRefreshStatus();
    // Only on first show of this panel.
  }, []);
  const plan = claudeStatus?.subscriptionType ? ` · ${claudeStatus.subscriptionType[0].toUpperCase()}${claudeStatus.subscriptionType.slice(1)}` : "";
  return (
    <>
      <Row label="연결 상태" detail="이 컴퓨터의 Claude Code 로그인을 사용합니다">
        {claudeStatus?.loggedIn ? (
          <span className="ok">● {claudeStatus.email ?? "Claude 계정"}{plan}</span>
        ) : busy ? (
          <button className="btn small" onClick={() => api.claudeCancel()}>취소</button>
        ) : (
          <button className="btn primary small" onClick={() => api.claudeSignIn()}>Claude 로그인</button>
        )}
      </Row>
      <Row label="모델">
        <select value={view.settings.claudeModel} disabled={busy} onChange={(e) => save({ claudeModel: e.target.value })}>
          {view.claudeModels.map(([id, title]) => (
            <option key={id} value={id}>{title}</option>
          ))}
        </select>
      </Row>
      <details className="advanced">
        <summary>고급</summary>
        <Row label="claude 실행 파일" detail="비워 두면 자동으로 찾습니다">
          <input type="text" value={path} placeholder="자동" onChange={(e) => setPath(e.target.value)} onBlur={() => path !== view.settings.claudePath && save({ claudePath: path })} />
        </Row>
        <Row label="상태 다시 확인">
          <button className="btn small" disabled={busy} onClick={() => api.claudeRefreshStatus()}>새로고침</button>
        </Row>
      </details>
    </>
  );
}

function ChatGptPanel({ view, save }: { view: SettingsView; save: Save }) {
  const { busy, chatgptModels } = view.connection;
  const active = view.chatgptProfiles.find((p) => p.clientId === view.activeClientId);
  return (
    <>
      {view.chatgptProfiles.length > 0 && (
        <Row label="계정">
          <select value={view.activeClientId ?? ""} disabled={busy} onChange={(e) => api.chatgptSelect(e.target.value)}>
            <option value="" disabled>계정 선택</option>
            {view.chatgptProfiles.map((p) => (
              <option key={p.clientId} value={p.clientId}>{p.label}</option>
            ))}
          </select>
        </Row>
      )}
      <Row label="연결 상태" detail="ChatGPT·Codex와 구독 한도를 공유합니다">
        {busy ? (
          <button className="btn small" onClick={() => api.chatgptCancel()}>취소</button>
        ) : active?.permitsInference ? (
          <span className="ok">● 구독 사용 중</span>
        ) : active?.connected ? (
          <button className="btn primary small" onClick={() => api.chatgptSignIn(false, true)}>구독 사용 허용</button>
        ) : (
          <button className="btn primary small" onClick={() => api.chatgptSignIn()}>Continue with ChatGPT</button>
        )}
      </Row>
      {active?.permitsInference && (
        <Row label="모델">
          <select value={view.settings.chatgptModel} disabled={busy || !chatgptModels.length} onChange={(e) => save({ chatgptModel: e.target.value })}>
            {!chatgptModels.length && <option value={view.settings.chatgptModel}>불러오는 중…</option>}
            {chatgptModels.map((m) => (
              <option key={m.slug} value={m.slug}>{m.displayName}</option>
            ))}
          </select>
        </Row>
      )}
      <div className="row-actions">
        <button className="btn ghost small" disabled={busy} onClick={() => api.chatgptSignIn(true)}>다른 계정 연결</button>
        {active?.connected && (
          <>
            <button className="btn ghost small" disabled={busy} onClick={() => api.chatgptRefreshModels()}>모델 새로고침</button>
            <button className="btn ghost small" disabled={busy} onClick={() => api.chatgptSignOut()}>로그아웃</button>
          </>
        )}
        <div className="spacer" />
        <button className="btn ghost small" onClick={() => api.openLink("https://chatgpt.com/settings/usage")}>사용량 ↗</button>
      </div>
    </>
  );
}

function ApiKeyPanel({ view, save }: { view: SettingsView; save: Save }) {
  const [key, setKey] = useState("");
  const [model, setModel] = useState(view.settings.apiModel);
  const [saved, setSaved] = useState<string | null>(null);
  const store = (value: string) =>
    api.saveApiKey(value).then(() => {
      setKey("");
      setSaved(value ? "키를 보안 저장소에 저장했습니다." : "키를 삭제했습니다.");
    });
  return (
    <>
      <Row label="API 키" detail={view.hasApiKey ? "저장됨 · 키체인/자격 증명 관리자" : "사용료는 별도로 청구됩니다"}>
        <input type="password" value={key} placeholder={view.hasApiKey ? "••••••••" : "sk-..."} onChange={(e) => setKey(e.target.value)} />
        <button className="btn small" disabled={!key.trim()} onClick={() => store(key)}>저장</button>
        {view.hasApiKey && <button className="btn ghost small" onClick={() => store("")}>삭제</button>}
      </Row>
      <Row label="모델" detail="이미지를 지원하는 모델">
        <input type="text" value={model} onChange={(e) => setModel(e.target.value)} onBlur={() => model.trim() && model !== view.settings.apiModel && save({ apiModel: model.trim() })} />
      </Row>
      {saved && <p className="message">{saved}</p>}
    </>
  );
}

function ShortcutRow({ name, field, view, save }: { name: string; field: keyof Shortcuts; view: SettingsView; save: Save }) {
  const [recording, setRecording] = useState(false);
  const value = view.settings.shortcuts[field];
  useEffect(() => {
    if (!recording) return;
    const onKey = (e: KeyboardEvent) => {
      e.preventDefault();
      if (e.key === "Escape") return setRecording(false);
      const accelerator = acceleratorFromEvent(e, isMac);
      if (!accelerator) return;
      setRecording(false);
      save({ shortcuts: { ...view.settings.shortcuts, [field]: accelerator } });
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [recording, field, save, view.settings.shortcuts]);
  return (
    <Row label={name}>
      <button className={`btn shortcut ${recording ? "recording" : ""}`} onClick={() => setRecording(!recording)}>
        {recording ? "키 조합 입력… (Esc 취소)" : displayAccelerator(value, isMac)}
      </button>
    </Row>
  );
}
