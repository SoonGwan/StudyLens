# StudyLens

[제품 소개 · 사용 흐름 · 설치 안내](https://study-lens.no-money-do-you-have-money.com/)
| [랜딩 개발 안내](landing/README.md)

StudyLens는 메뉴바(Windows는 작업 표시줄 트레이)에 조용히 상주하는 개인 학습 보조 앱입니다. 평소에는 작은 점 아이콘으로만 있고, 단축키를 누를 때만 나타납니다.

1. **영역 캡처:** 단축키를 누르고 화면 영역을 직접 선택하면 그 이미지로 설명을 받습니다.
2. **선택 텍스트:** 앱이나 웹페이지에서 텍스트를 드래그하고 단축키를 누르면 선택한 텍스트만 보내 답과 설명을 받습니다.
3. **코드 바로 복사:** 문제를 드래그하고 단축키를 누르면 결과 창 없이 완성된 코드만 클립보드에 넣습니다.

일반 설명은 결과 창에서 복사 버튼을 눌러 복사합니다. **코드 바로 복사**만 성공 시 자동으로 클립보드를 갱신하며, 붙여넣기는 사용자가 직접 합니다.

진행 중인 시험이나 감독 환경에서 몰래 답을 제공하거나, 화면 공유에서 창을 숨기거나, 다른 앱으로 위장하거나, 답안을 자동 입력하는 기능은 없습니다. 분석 지침에도 시험·감독 화면으로 판단되면 정답 대신 일반적인 개념 복습만 제공하도록 명시되어 있습니다.

## 0.3.0: Tauri 2로 재작성

SwiftUI 앱을 [Tauri 2](https://v2.tauri.app/)(Rust + React)로 다시 만들었습니다. macOS와 Windows를 같은 코드로 지원하며, 설치 파일은 약 5 MB입니다. 0.2.x의 기능(ChatGPT·Claude Code·API 키 연결, 추론 강도, 진행·취소, 그림 첨부, 코드 바로 복사)을 모두 유지합니다.

달라진 점:

- 메뉴바 아이콘은 그냥 클릭하면 메뉴가 열립니다(이전에는 ⌥-클릭).
- 처음 실행하면 설정 창과 짧은 안내가 열립니다.
- 결과 창에 단계별 진행과 경과 시간이 표시되고, 창이나 메뉴에서 요청을 취소할 수 있습니다.
- Windows: 영역 캡처는 화면을 멈춘 뒤 드래그해서 선택하고, 선택 텍스트는 UI Automation으로 읽습니다. **Windows는 컴파일만 확인했고 실기기 검증 전입니다.**

## 요구 사항

- macOS 13 이상 또는 Windows 10/11
- 다음 중 하나
  - 로그인된 Claude Code (Claude Pro·Max 구독)
  - 구독 연동을 지원하는 ChatGPT Plus·Pro 계정
  - OpenAI API 키
- 소스 빌드: [Bun](https://bun.sh) 1.1 이상, Rust (rustup), macOS는 Xcode Command Line Tools, Windows는 [Tauri 사전 요구 사항](https://v2.tauri.app/start/prerequisites/)

## 설치

공개 바이너리 릴리스는 아직 없어서 소스에서 빌드합니다.

```bash
git clone https://github.com/SoonGwan/StudyLens.git
cd StudyLens
bun install
bun run app:build
open src-tauri/target/release/bundle/dmg
```

`.dmg`를 열고 StudyLens를 **응용 프로그램** 폴더로 옮긴 뒤 실행합니다. 처음 실행할 때 macOS가 개발자 확인 경고를 표시하면 앱을 Control-클릭하고 **열기**를 선택하세요. 빌드는 로컬 실행용 임시(ad-hoc) 서명입니다. 다른 사람에게 배포하려면 Developer ID 서명과 Apple 공증을 따로 설정해야 합니다.

Windows에서는 같은 명령으로 `src-tauri/target/release/bundle/nsis/`에 설치 파일이 만들어집니다.

## 처음 설정

1. 앱을 처음 실행하면 설정 창이 열립니다. 이후에는 메뉴바의 점 아이콘을 클릭하고 **설정…**을 엽니다.
2. **AI 연결**에서 Claude, ChatGPT, API 키 중 하나를 고릅니다(아래 각 절 참고).
3. 필요하면 **단축키**를 바꿉니다. Command·Control·Option 중 하나를 포함해야 하고, 다른 StudyLens 기능과 겹칠 수 없습니다. 다른 앱이 이미 쓰는 조합이면 등록 실패를 설정에 표시합니다.
4. macOS는 **권한**에서 현재 상태를 확인하고 필요한 권한을 허용합니다. 캡처에는 화면 기록, 선택 텍스트에는 손쉬운 사용 권한이 필요합니다.

기본 단축키:

| 기능 | macOS | Windows |
| --- | --- | --- |
| 영역 캡처 | ⇧⌘9 | Ctrl+Shift+9 |
| 선택 텍스트 설명 | ⇧⌘0 | Ctrl+Shift+0 |
| 코드 바로 복사 | ⇧⌘8 | Ctrl+Shift+8 |

## Claude 구독 사용량으로 사용하기 (Claude Code)

Anthropic은 서드파티 앱용 구독 로그인(OAuth)을 제공하지 않습니다. 그래서 StudyLens는 Claude 토큰을 직접 다루지 않고, 이 컴퓨터에 설치되어 로그인된 **Claude Code**(`claude` CLI)를 헤드리스 모드(`claude -p`)로 실행해 요청합니다. 요청은 Claude Code와 같은 구독 사용 한도를 공유합니다.

1. [Claude Code](https://code.claude.com)를 설치합니다.
2. 설정의 **AI 연결**에서 **Claude**를 선택합니다.
3. 로그인되어 있지 않으면 **Claude 로그인**을 누릅니다. Claude Code가 브라우저 로그인을 처리합니다. 진행되지 않으면 터미널에서 `claude auth login`을 실행하세요.
4. 모델(Claude Code 기본값·Opus·Sonnet·Haiku)을 고르고 단축키로 요청합니다.

- `claude`는 `~/.local/bin`, `~/.claude/local`, Homebrew, nvm·volta·bun 설치 경로, 로그인 셸의 `PATH` 순으로 찾습니다. 찾지 못하면 설정 → 고급에 실행 파일 경로를 직접 입력하세요.
- 사용자의 Claude Code 설정·MCP 서버·스킬·도구를 불러오지 않고(`--setting-sources ""`, `--strict-mcp-config`, `--tools ""`), 세션 기록도 남기지 않습니다(`--no-session-persistence`).
- StudyLens는 Claude Code의 인증 정보를 읽거나 저장하지 않습니다. 개인 컴퓨터에서 본인 계정으로 쓰는 용도이며, 다른 사람에게 Claude 로그인을 제공하는 배포용 기능이 아닙니다.
- Claude 연결은 Claude Code의 기본 추론 설정을 쓰며, 추가 지시는 지원하지만 선택 텍스트와 그림을 함께 보내는 첨부는 지원하지 않습니다.

## ChatGPT 구독 사용량으로 사용하기

공식 **Sign in with ChatGPT**를 사용합니다. API 키 없이 지원되는 계정의 구독 사용량 또는 허용된 크레딧으로 요청을 보낼 수 있습니다. 계정·워크스페이스·지역 정책에 따라 사용할 수 없을 수도 있습니다.

1. 설정의 **AI 연결**에서 **ChatGPT**를 선택하고 **Continue with ChatGPT**를 누릅니다.
2. 브라우저에서 로그인하고 StudyLens가 구독 사용량을 사용하도록 허용합니다.
3. 앱으로 돌아오면 계정에서 제공하는 모델 목록이 나타납니다. 원하는 모델을 고릅니다.

이 요청은 ChatGPT·Codex와 구독 한도를 공유합니다. [ChatGPT 사용량 설정](https://chatgpt.com/settings/usage)에서 앱별 한도와 크레딧 사용 여부를 조정할 수 있습니다. 한도나 연결 오류가 나도 API 키 결제로 자동 전환하지 않습니다.

로그인은 기본 브라우저와 로그인 중에만 열리는 `127.0.0.1` 콜백으로 진행합니다. 앱 자체 등록, PKCE, state·nonce 확인, OpenAI 공개 키를 이용한 ID 토큰 서명 검증을 구현했습니다. 다른 앱의 로그인 파일이나 브라우저 쿠키를 읽지 않습니다. 토큰은 OS 보안 저장소에 저장하고 만료되면 갱신합니다. 로그아웃하면 서버의 갱신 토큰 취소를 요청하고 로컬 토큰을 지웁니다.

요청은 `https://api.openai.com/v1/responses`로 보내며 `store: false`, `stream: true`를 적용합니다. 응답 완료 이벤트를 받은 경우에만 결과와 복사 버튼을 활성화합니다.

공식 근거: [연동 개요](https://developers.openai.com/siwc/token-sharing-open-source), [로그인](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [모델과 추론](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference), [현재 제약](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations).

## API 키로 사용하기

설정의 **AI 연결**에서 **API 키**를 선택하고 OpenAI API 키를 저장합니다. 기본 모델은 `gpt-4.1-mini`이며 바꿀 수 있습니다. 사용료는 OpenAI API 플랫폼에서 별도로 청구됩니다.

## 사용 흐름

- **영역 캡처:** 단축키를 누르고 십자 커서로 영역을 드래그합니다. `Esc`로 취소합니다. 결과 창에 캡처 이미지와 설명이 나옵니다.
- **선택 텍스트:** 텍스트를 드래그한 직후 단축키를 누릅니다. 본문 끝에 "Java 코드로 만들어줘", "설명만 해줘", "번역해줘"처럼 요청을 함께 선택하면 그 언어와 형식에 맞춰 답합니다.
- **코드 바로 복사:** 문제를 드래그하고 단축키를 누르면 결과 창 없이 코드만 클립보드에 넣습니다. 진행 중에는 메뉴바 점이 주황색, 완료는 초록색, 실패는 빨간색입니다. 실패해도 결과 창을 자동으로 열지 않으며, 메뉴의 **결과 보기**로 실제 응답을 확인할 수 있습니다.
- **진행과 취소:** 결과 창 위쪽에 현재 단계(선택 읽기·그림 선택·연결 준비·응답 대기·작성·복사)와 경과 시간이 표시되고, 누르면 단계별 시간을 볼 수 있습니다. 결과 창의 **취소** 또는 메뉴의 **현재 요청 취소**로 멈춥니다. 취소한 요청의 결과는 버리고 클립보드는 건드리지 않습니다. 자동 재시도는 하지 않습니다.
- **추론 강도:** 설정에서 빠르게(low)·균형(medium)·깊게(high)·모델 기본값을 고릅니다. 연결 방식과 모델별로 저장되며, 지원이 확인된 모델에만 `reasoning.effort`를 보냅니다. 설정에 실제로 보내는 값이 표시됩니다.
- **그림 첨부와 추가 지시:** 설정 → 선택 텍스트 입력에서 그림 첨부를 켜면 텍스트를 읽은 뒤 직접 선택한 그림 영역 한 장을 같은 요청에 보냅니다(OpenAI 연결, 이미지 지원이 확인된 모델만). 추가 지시는 모든 텍스트·코드 요청 뒤에 붙습니다. 본문 30,000자, 추가 지시 2,000자, PNG 한 장 10 MiB까지이며 전송 전에 검사합니다.

### 코드 표시와 복사

코드 블록은 설명과 분리해 고정폭 글꼴로 표시하며 줄바꿈·탭·들여쓰기를 유지합니다. 각 블록의 **복사**, 또는 코드 블록이 하나일 때 하단의 **코드만 복사**를 누르면 설명과 Markdown 구분자 없이 코드 원문만 복사합니다. **전체 복사**는 응답 원문 전체를 복사합니다.

코드 바로 복사는 완료된 응답의 닫힌 코드 블록 하나만 복사합니다. Markdown 구분자가 없는 단독 Java 클래스는 시작 구문과 문자열·주석 바깥 괄호 균형을 확인해 복사합니다. 이것은 형식 검사이며 컴파일·정답 검증이 아닙니다. 코드 없음, 여러 코드 블록, 닫히지 않은 블록, 빈 블록, 네트워크 오류일 때는 기존 클립보드를 그대로 둡니다.

저장한 UTF-8 결과 텍스트를 AI 요청 없이 다시 표시하려면 `--result-file /absolute/path/result.txt` 인자로 앱을 실행하세요.

## 권한 및 개인정보

- **화면 기록(macOS):** 사용자가 직접 선택한 영역을 캡처하는 데 필요합니다.
- **손쉬운 사용(macOS):** 선택 텍스트를 읽을 때만 필요합니다. 앱에 포함된 작은 Swift 도우미(`studylens-helper`)가 접근성 API로 선택 영역만 읽습니다. ⌘C를 보내거나 클립보드를 읽지 않고, 선택이 없을 때 페이지 전체를 대신 보내지 않으며, 비밀번호·숨김 영역은 읽지 않습니다. Chromium 브라우저에서는 읽는 동안만 접근성 정보를 켜고 원래 값으로 되돌립니다.
- **업데이트 후 권한:** 임시 서명 앱은 다시 빌드하면 서명이 바뀌어 스위치가 켜져 있어도 허용이 무효일 수 있습니다. 설정의 권한 상태가 "접근 불가"로 보이면 StudyLens를 종료하고 시스템 설정 목록에서 기존 항목을 지운 뒤 새 앱을 다시 추가하고 재실행하세요.
- **네트워크:** 선택한 이미지나 텍스트는 고른 연결(OpenAI 또는 Claude Code)로 전송됩니다.
- **보안 저장소:** API 키와 ChatGPT 연결 정보는 macOS 키체인 / Windows 자격 증명 관리자의 `com.studylens.app` 서비스에 저장합니다. 일반 설정은 앱 설정 폴더의 `settings.json`에 저장합니다.
- **임시 이미지:** 캡처 파일은 읽은 직후 삭제합니다.
- **진단:** 모델·강도·연결 방식·단계별 시간만 메모리에 유지합니다. 선택 원문·코드·인증 토큰을 기록하거나 업로드하지 않습니다.

## 개발

```bash
bun install
bun run app:dev     # Swift 도우미를 빌드하고 개발 모드로 실행
bun run test        # 프론트엔드(vitest) + Rust + Swift 도우미 테스트
bun run typecheck
```

`app:dev`로 실행하면 macOS가 StudyLens 대신 실행한 터미널 앱에 권한을 요구할 수 있습니다. 권한까지 확인하려면 `bun run app:build`로 만든 앱을 쓰세요.

## 주요 구조

- `src-tauri/src/`: Rust 백엔드
  - `core.rs`: 앱 상태, 세 가지 기능의 흐름, 요청 ID 기반 취소
  - `inference/`: 공통 인터페이스(`InferenceProvider`)와 Claude Code·OpenAI 구현, 공용 프롬프트, 모델별 기능(`capabilities.rs`), 스트림 파싱
  - `auth/`: Sign in with ChatGPT(PKCE, 루프백 콜백, ID 토큰 검증)
  - `platform/`: macOS(`screencapture`, Swift 도우미) / Windows(화면 고정 후 드래그 선택, UI Automation)
  - `document.rs`, `quick_code.rs`: 응답의 코드 블록 분리와 코드 바로 복사 판정
  - `tray.rs`, `hotkeys.rs`, `ui.rs`, `settings.rs`, `secrets.rs`, `progress.rs`
- `native/`: macOS 선택 텍스트용 Swift 도우미
- `src/`: React 화면(결과 창, 설정 창, Windows 캡처 오버레이)
- `landing/`, `brand/`: 제품 소개 페이지와 브랜드 자산

## 알려진 제한

- Windows는 컴파일만 확인했고 실기기에서 검증하지 않았습니다. 선택 텍스트는 UI Automation을 지원하는 앱에서만 읽을 수 있습니다.
- 전역 단축키가 다른 앱의 단축키와 충돌하면 등록되지 않을 수 있습니다. 설정에서 다른 조합을 고르세요.
- 모델별 이미지 입력 지원과 API 요금은 계정과 모델에 따라 다릅니다. ChatGPT 구독 연동은 계정·워크스페이스에 따라 제한될 수 있습니다.
- 실제 ChatGPT 로그인과 구독을 소비하는 요청은 자동 테스트하지 않습니다. 0.2.x의 이슈별 검증 기록은 [docs/issue-verification.md](docs/issue-verification.md)에 있습니다(SwiftUI 버전 기준).
