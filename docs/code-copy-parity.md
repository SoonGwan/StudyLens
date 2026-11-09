# Swift → Rust 코드 복사 동등성 검증

관련 이슈: #1, #6. 이전 Swift 구현의 합성 사례 37개를 Rust의 코드 추출·표시 데이터와 대조합니다.

원본: 커밋 `8702612`, `Tests/StudyLensTests/CodeCopyFixtureTests.swift`.
Java/Python/C++ × LF/CRLF × fence/설명 포함/여러 블록/빈 블록/미완료/raw 36개와 코드 없음 1개입니다.
사용자의 실제 응답·선택 텍스트를 수집하지 않습니다.

작업 범위는 공유 합성 fixture, Rust 동등성 검사, 실제 React 결과 화면의 모의 IPC 회귀 검사입니다.
권한 화면(PR #12), AI 속도 비교, 서명·패키징, 실기기 업데이트, Windows 실기기는 포함하지 않습니다.

## 검증 범위

- Rust 자동 복사 후보와 오류 종류, 표시용 코드 블록의 원문·완결 상태를 37개 사례와 대조합니다.
- Rust가 만든 블록 데이터를 실제 결과 화면에 보내고 전체/블록 복사 버튼의 명령과 표시 문자를 확인합니다.
- 전체 Tauri 실행 흐름·실제 OS 클립보드 보존 검증과 모의 검사를 구분합니다.

## 재현

```sh
bun install
bun run build:helper
STUDYLENS_COPY_QA_OUTPUT=/tmp/studylens-code-copy-snapshots.json cargo test --manifest-path src-tauri/Cargo.toml --locked
bun run build
bunx vitest run
```

브라우저 검사에는 Ego Lite가 필요합니다. 다음 개발 서버를 실행하고 다른 터미널에서 runner를 실행합니다.
포트가 이미 사용 중이면 해당 프로세스를 종료하지 않고 서버·runner 주소를 함께 변경합니다.

```sh
bunx vite --host 127.0.0.1 --port 15440 --strictPort
ego-browser nodejs < scripts/test-code-copy-browser.mjs
```

`STUDYLENS_COPY_QA_OUTPUT`는 테스트에서만 읽습니다. Rust가 현재 소스로 파싱한 실제 블록 데이터를 저장하므로 브라우저 검사 전에 반드시 다시 생성합니다.
결과 화면은 실제 컴포넌트이고 IPC만 모의합니다. 브라우저 fixture 페이지는 제품 빌드 입력에 포함하지 않습니다.

## 결과

- Rust 68개 통과. 새 동등성 테스트 하나가 Swift 합성 사례 37개를 각각 검사합니다.
- `bun run build`의 타입 검사·프런트 빌드, 기존 프런트 테스트 7개 통과.
- Ego 브라우저에서 37개 전체 통과: 코드 원문·LF/CRLF·탭·빈 줄·주석의 DOM 문자 일치, 전체 복사 명령, 개별 블록/단일 코드 복사 ID, 빈/미완료 블록 버튼 비활성화, 여러 블록의 단일 코드 버튼 생략.

이 검사는 코드 추출과 화면 표시·명령 전달의 회귀 검사입니다.
실제 AI 응답 품질·low/medium 지연 차이, 전역 단축키, 취소 후 실제 클립보드 유지, Windows 실기기와 OS 클립보드 API 호출은 검증하지 않습니다.
따라서 이 결과만으로 #1 또는 #6을 닫지 않습니다.
