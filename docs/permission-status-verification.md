# macOS 권한 상태 조회 검증

관련 이슈: #3, #6. 작업 범위는 설정 화면의 macOS 권한 조회 상태와 재조회입니다.
다른 세션은 서명·패키징, 실제 업데이트 설치, Windows 실기기 검증,
AI 연결·추론 속도 비교를 독립적으로 진행할 수 있습니다.

## 확인할 동작

- [x] 최초 조회가 끝나기 전에는 권한 거부로 표시하지 않습니다.
- [x] 조회 실패와 권한 거부를 구분하고, 사용자가 다시 확인할 수 있습니다.
- [x] 창에 돌아오면 다시 조회하고, 이전 조회의 성공·실패가 늦게 끝나도 최신 결과를 덮지 않습니다.
- [x] Windows에서는 macOS 전용 권한 영역을 표시하지 않습니다(기존 `view.platform === "macos"` 조건 확인, Windows 실기기는 미검증).
- [x] 상태 조회는 권한 요청이나 TCC 설정 변경을 실행하지 않습니다(프런트엔드 호출과 Rust 조회 함수 확인).

## 검증 현황

- 변경 전 TypeScript 검사와 프런트엔드 테스트 7개 통과.
- 변경 전 Swift 테스트는 로컬 Command Line Tools의 XCTest 모듈 부재로 실패.
- 변경 후 `bun run build`(타입 검사 포함), `bunx vitest run` 7개 통과.
- `cargo test --manifest-path src-tauri/Cargo.toml --locked`: Rust 67개 및 문서 테스트 통과.
- `bun run test:helper`: 실제 Swift 도우미 빌드와 프로토콜 7개 통과. XCTest 모듈을 요구하는 Swift 단위 테스트와는 별도 검사입니다.
- Ego 브라우저에서 모의 IPC로 조회 중·실패·수동 재조회·부분 허용·창 복귀·이전 조회의 늦은 실패/성공·사용 불가 응답·복구·두 설정 링크 호출을 검증했습니다. 실제 OS 권한 변경은 하지 않았습니다.
- 현재 컴포넌트를 직접 렌더링하는 브라우저 검사이며 Tauri 앱 전체 E2E나 실제 업데이트 검증을 대신하지 않습니다.
- 실기기 업데이트 후 권한 유지와 실제 선택 읽기·캡처는 이 문서의 자동 검사 범위 밖입니다.

## 브라우저 회귀 검사 재현

`bun install` 후 터미널 두 개에서 실행합니다. 다른 세션이 이미 포트를 사용한다면 그 프로세스를 종료하지 말고, 서버와 runner의 주소를 함께 다른 포트로 맞춥니다.

```sh
bunx vite --host 127.0.0.1 --port 15439 --strictPort
ego-browser nodejs < scripts/test-permissions-browser.mjs
```

`tests/browser/permissions.html`은 개발 서버에서만 쓰는 모의 IPC 페이지입니다.
제품의 Vite 빌드 입력에는 포함하지 않습니다. AI·키체인·클립보드·시스템 권한을 호출하지 않습니다.
검사 중 브라우저의 실제 focus 이벤트를 받은 뒤 응답 순서를 제어하므로, 검사 페이지를 조작하지 않은 상태로 실행합니다.
