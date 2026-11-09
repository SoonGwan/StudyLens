# 데스크톱 자동 검사와 패키징

관련 이슈: #6. 담당 범위는 `.github/workflows/desktop-validation.yml`과 이 문서입니다.
앱 구현·권한 화면(PR #12)·복사 fixture(PR #13)·캡처 취소(PR #14)는 수정하지 않습니다.

macOS와 Windows 호스팅 실행기에서 잠금 파일을 사용해 의존성을 설치하고,
타입·프런트 테스트·Rust 테스트·플랫폼별 설치 파일 생성을 확인합니다.
macOS에서는 Swift 단위 테스트·도우미 프로토콜·서명/DMG 무결성 검사도 실행합니다.

로그인·AI 요청·실제 화면·키체인·사용자 클립보드를 사용하지 않고, 공개 릴리스를 배포하지 않습니다.
Windows NSIS 패키징 성공은 실제 PC의 설치·실행·UI Automation·다중 모니터 검증 완료를 뜻하지 않습니다.

## 실행과 결과 확인

PR, `main` 또는 `ci/**` 브랜치 push, 수동 실행으로 동작합니다.
권한은 `contents: read`이고 checkout 인증 정보는 저장하지 않습니다.
세 외부 Action은 확인한 커밋 SHA로 고정하고 Bun은 1.4.3, Rust는 현재 stable을 사용합니다.
macOS 빌드는 기본 ad-hoc 서명이며 인증서 서명·공증을 실행하지 않습니다.

성공한 설치 파일은 실행의 Artifacts에 `studylens-validation-<os>-<sha>` 이름으로 7일간 보관합니다.
설치 파일이 없으면 업로드 단계가 실패합니다. 실제 앱을 설치하거나 공개 릴리스를 생성하지 않습니다.
워크플로 문법은 `actionlint` 1.7.12로 검사했습니다.

검증 실행과 최종 결과는 [PR #15](https://github.com/SoonGwan/StudyLens/pull/15)에 기록합니다.
첫 실행에서 Windows의 잠금 파일 설치·타입·프런트·Rust 검사가 통과했고,
PR #12·#13·#14가 머지된 `main`을 반영해 전체 패키징 검증을 다시 실행합니다.
