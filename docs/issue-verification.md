# StudyLens 0.2.6 검증 기록

대상은 GitHub 이슈 #1~#5입니다. 로컬 구현과 합성 입력·가짜 네트워크 검증을 진행했으며, 실제 사용자 로그인/AI 요청·인증서 발급·권한 변경은 실행하지 않았습니다. 원격 이슈를 완료로 닫거나 앱을 설치·배포하지 않았습니다.

자동 검증: `swift test` 66개 통과(실패 0), `./build-app.sh` 릴리스 빌드 성공, 생성 앱의 `codesign --verify --strict` 통과, `zsh -n build-app.sh` 및 `git diff --check` 통과. 앱 버전은 0.2.6/빌드 8입니다.

## #1 추론 강도

`ReasoningSettings`는 빠르게/균형/깊게/모델 기본값을 모델과 연결 방식별로 저장합니다. 문서로 확인한 exact alias인 `gpt-6.1-sol`, `gpt-6-astra`, `gpt-6-sol`, `gpt-6-luna`, `gpt-5.2`, `gpt-5.1`, `gpt-5`에 low/medium/high를 제공하고 신규 기본값은 low입니다. API와 ChatGPT 목록에서 같은 alias를 선택했을 때 같은 규칙을 적용합니다. 구독 계정에 해당 모델이 없으면 기존 연결 검증에서 요청을 거부합니다. 현재 등록하지 않은 모델·snapshot·전용 pro/codex alias에는 `reasoning`을 생략합니다. 서버 slug를 임의로 다른 모델로 바꾸지 않습니다.

지원하지 않는 저장 값은 모델 기본값으로 재검증합니다. 모델·강도·연결 방식·기본 언어·추가 지시·첨부 여부는 요청 시작 시 고정합니다. 설정 UI에 실제 전송 값 또는 필드 생략을 표시합니다. GPT-6.1 Sol에 none/minimal을 보내지 않습니다. 출력 토큰 제한은 기존 값이며 완료 전의 코드를 복사하지 않습니다.

검증: `ReasoningSettingsTests`, `InferenceTransportTests`의 이미지 설명·텍스트 설명·코드 생성 × 두 연결 방식 × low/medium/high JSON 검증, 미지원·unknown·모델 기본값 생략, `RequestWorkflowTests`의 시작 후 설정 변경 검증.

공식 근거(2026-10-10 확인): [GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol), [GPT-6 family의 effort](https://developers.openai.com/api/docs/guides/deployment-checklist), [GPT-5](https://developers.openai.com/api/docs/models/gpt-5), [GPT-5.1](https://developers.openai.com/api/docs/models/gpt-5.1), [GPT-5.2](https://developers.openai.com/api/docs/models/gpt-5.2), [Reasoning 안내](https://developers.openai.com/api/docs/guides/reasoning), [ChatGPT 구독용 모델·요청](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference).

### 사용자 요청으로 실행할 비교

아직 low/medium 실제 사용량 비교는 수행하지 않았습니다. 사용자가 명시적으로 실행할 때만 동일한 모델·본문·연결 방식으로 각 강도에서 최소 3회 요청하세요. 각 요청은 구독 사용량 또는 API 비용을 소비합니다. 다음 표를 기록하고 결과 창에서 코드를 수동으로 복사한 뒤 독립적으로 컴파일·예제를 실행하세요. StudyLens는 응답 코드를 자동 실행하지 않습니다.

| 강도 | 회차 | 선택 읽기 | 인증·모델 확인 | 첫 SSE 이벤트 | 첫 출력 | 응답 완료 | 총 시간 | 컴파일·예제 결과 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| low | 1~3 | 미측정 | 미측정 | 미측정 | 미측정 | 미측정 | 미측정 | 미검증 |
| medium | 1~3 | 미측정 | 미측정 | 미측정 | 미측정 | 미측정 | 미측정 | 미검증 |

## #2 단계별 진행과 취소

입력 읽기·직접 그림 선택·연결 준비·응답 대기·작성·복사 단계와 총 경과 시간을 메모리에 유지합니다. 선택 읽기와 인증/모델 확인은 각 단계의 소요 시간이며 첫 SSE 이벤트·첫 출력·완료는 요청 시작 이후 경과 시간입니다. 두 연결 방식 모두 stream=true를 요청합니다. JSON을 반환하는 호환 transport에서는 완료 status를 요구하고 SSE 시간은 표시하지 않으며 첫 출력은 전체 body를 받은 시점입니다.

메뉴와 결과 창에서 현재 요청을 취소합니다. 보유한 Task를 취소해 URLSession 로딩과 화면 영역 선택 Process에 전파하고, 요청 ID를 무효화해 늦은 상태·클립보드 갱신을 막습니다. 이전 작업이 뒤늦게 끝나도 새 요청을 지우지 않습니다. 취소·시간 초과·네트워크 실패를 구분하고 재시도는 사용자가 단축키/메뉴로 직접 시작합니다. 코드 복사 모드는 성공·실패·취소 시 결과 창을 자동으로 열지 않습니다.

검증: `NetworkCancellationTests`의 미완료 SSE 로딩 중단과 재시도 없음, `RequestWorkflowTests`의 취소된 선택/늦은 응답/다음 요청/시간 초과 구분, 실제 별도 NSPasteboard의 내용 보존. 실제 서비스의 단계별 속도·실제 capture Process 취소는 실기기 확인이 남아 있습니다.

## 서명과 권한 업그레이드

기본 `./build-app.sh`는 ad-hoc, `--identity` 또는 `STUDYLENS_SIGNING_IDENTITY`는 설치된 인증서 서명입니다. bundle ID `com.example.StudyLens`를 유지하며 서명 검증에 실패하면 기존 산출물을 교체하지 않습니다. 명시적 인증서 서명은 hardened runtime과 timestamp를 사용하며 별도의 공증 절차가 필요합니다. 공증 자격 증명·개인 키·토큰은 저장소나 로그에 넣지 마세요. 인증서 선택은 코드 서명용 identity 이름/지문이며 비밀 키를 전달하는 인자가 아닙니다.

설정은 `AXIsProcessTrusted()`와 `CGPreflightScreenCaptureAccess()`를 사용해 현재 프로세스의 실제 허용을 조회합니다. 창 활성화·새로고침 시 다시 조회하며 권한 요청·TCC DB 변경·다른 앱의 권한 초기화는 하지 않습니다. 개별 외부 앱이 선택 내용을 제공하는지까지 이 조회로 보장하지 않습니다.

다음 실기기 업그레이드 검증은 아직 수행하지 않았습니다. 기존 설치 앱·권한을 변경하지 않고 local build만 검사했습니다.

| 경우 | 확인 |
| --- | --- |
| 같은 bundle ID·identity·설치 경로, 이전→새 버전 | 선택 읽기·직접 영역 캡처 및 두 권한 상태 확인 |
| 같은 ID·경로, ad-hoc 바이너리 교체 | 켜진 스위치에도 현재 프로세스 trust/preflight가 실패할 수 있음; 복구 안내 확인 |
| bundle ID 변경 | 별도 앱으로 권한 등록이 필요한지 확인 |
| 설치 경로 변경 | 새 경로 등록·실행 결과 확인 |
| signing identity/ad-hoc↔인증서 변경 | 서명 요구사항 변경 전후 권한 재등록 필요 여부 확인 |

복구: 앱 완전 종료 → 시스템 설정의 손쉬운 사용에서 오래된 StudyLens 항목 제거 → 새 앱을 기존 설치 경로에 배치 → 새 항목 등록·허용 → 재실행. 화면 기록 권한은 별도로 확인합니다. 로그인·사용량 오류와 구분해 처리하세요. Developer ID 서명·공증 자체와 반복 업그레이드의 권한 유지 여부는 인증서가 제공된 환경에서 확인해야 합니다.

## #4 코드 표시·복사

`CodeCopyFixtureTests`는 사용자 응답이 아닌 합성 사례 37개로 Java/Python/C++ × LF/CRLF × fenced·설명+fence·다중 블록·빈 블록·미완료·raw를 검증합니다. 같은 fixture를 표시용 `ResponseDocument`, AppModel 개별 블록 복사, 전체 복사, 단축키 자동 복사에 사용하며 각 경로는 실제 별도 NSPasteboard를 거칩니다. 테스트는 사용자 일반 클립보드를 덮어쓰지 않습니다.

CRLF를 Swift Character로 읽을 때 `//` 주석 종료가 감지되지 않던 raw Java 검사를 수정했습니다. 바로 닫힌 빈 fence는 emptyCode로 인식합니다. CRLF 원문 끝에 LF를 추가해 바꾸지 않습니다.

구분자 없는 원문은 Java 단독 class 시작 구문과 문자열/주석 바깥 괄호 균형을 확인하는 기존 범위만 유지합니다. 이는 컴파일 검증이 아니며 Java의 모든 문법(예: 복잡한 text block)을 지원하지 않습니다. raw Python/C++ 등은 자동 복사하지 않습니다. 사용자는 실패 후 결과를 수동으로 열어 전체 응답이나 완료된 개별 fenced 블록을 복사할 수 있습니다. 여러 블록을 합치거나 설명을 자동 복사하지 않습니다. 사용자 제공 실패 응답 fixture는 제공·동의가 없어 추가하지 않았습니다. 응답을 자동 수집/업로드하지 않습니다.

## #5 선택 텍스트 + 직접 그림 영역

첨부 설정의 기본값은 꺼짐이며 기존 전역 단축키를 유지합니다. 켠 경우 텍스트를 먼저 읽고 직접 선택하는 그림 영역을 받습니다. 본문·추가 지시·그림 한 장을 하나의 user message의 content 항목으로 보냅니다. 그림 파일명만 있는 텍스트에도 기존 지침대로 가능한 답변을 제공하고 확인하지 않은 그림을 지어내지 않습니다.

선택 본문 30,000자·추가 지시 2,000자·PNG 한 장 10 MiB가 앱 한도입니다. 그림 지원은 검증한 exact model alias 목록을 사용하며 목록 밖은 보내지 않습니다. API 키/구독에 같은 이미지 지원 규칙을 적용하고 구독 계정의 실제 모델 허용은 별도 credential 준비에서 확인합니다. 페이지 전체·다른 창·클립보드 이미지를 대신 읽지 않습니다. 이미지 권한은 캡처 시작 전 확인하며 복사 모드에서는 권한 요청 팝업 없이 preflight 실패를 상태로 안내합니다. 이미지 종류/크기는 서버로 보내기 전에 검사합니다.

검증: `InferenceTransportTests`의 두 연결 방식 combined JSON, 실제 AppModel의 텍스트→이미지→credential 순서, 첨부 꺼짐 기존 흐름, 잘못된 이미지/크기/unknown 모델/긴 지시의 네트워크 전 차단, picker 취소 후 클립보드 보존·요청 없음·창 자동 열기 없음. 실제 외부 앱 선택→권한 허용→이미지 입력 요청은 사용자가 직접 확인해야 합니다.
