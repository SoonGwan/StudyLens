# StudyLens landing

한국어 제품 소개 페이지입니다. [이슈 #10](https://github.com/SoonGwan/StudyLens/issues/10)의
Questionable Hires 방향을 바탕으로 Montage 색상과 전용 캐릭터 렌즈를 사용합니다.
앱 실행 코드와 분리된 HTML/CSS/작은 JavaScript이며, 방문자가 AI 요청을 보내거나
로그인할 수 있는 기능은 없습니다. 추적 코드·외부 폰트·런타임 의존성도 없습니다.

공개 주소: **https://study-lens.no-money-do-you-have-money.com/**

## 수정 위치

- `index.html`: 한국어 본문, 링크, 메타데이터, 기능·설치·연결·FAQ.
- `app.js`: 고정 예시와 단계별 데모, 사용자가 누르는 복사 버튼.
- `style.css`: Montage 토큰, 반응형 레이아웃, 키보드 포커스와 모션 감소.
- [브랜드 원본·재생성 안내](../brand/README.md): 캐릭터, 실제 앱 결과 화면, OG, 아이콘.

버전은 빌드 시 `src-tauri/tauri.conf.json`에서 읽습니다. 플랫폼·릴리스·연결 설명은
README와 구현을 함께 확인해 수정하세요. 앱은 Tauri 2(macOS·Windows)이며, Windows는
컴파일만 확인했고 공개 GitHub Release는 아직 없습니다.
속도·메모리 수치나 모든 앱의 호환성을 주장하지 않습니다.

## 빌드와 미리보기

```sh
python3 -B scripts/build_landing.py
python3 -B scripts/serve_landing.py --directory .build/landing --port 4182
```

http://127.0.0.1:4182/ 를 확인하세요. 기본 출력 `.build/landing/`에는 공개할
HTML/CSS/JS와 선택한 웹 자산, robots, sitemap, release manifest만 들어갑니다.
캐릭터 원본·소스·인증 정보·문서·개발 의존성은 배포하지 않습니다.
실제 공개 origin 변경 시 `--site-url https://새주소`로 canonical·OG·sitemap을 함께 생성합니다.

## 브라우저 검증

```sh
npm ci --prefix tools/landing
node scripts/check_landing.cjs http://127.0.0.1:4182/
```

설치된 Chrome을 사용합니다. 360px·태블릿·데스크톱의 가로 넘침, 이미지 로딩,
메타데이터, 키보드 탐색, 모션 감소, axe 접근성, 세 가지 데모의 단계·초기화·복사,
지연된 클립보드 완료 후 방식 전환, 복사 거부 후 복구, JavaScript 비활성 상태를 검증합니다.
스크린샷은 `docs/landing/`에 저장합니다. 앱 로그인이나 유료 요청을 검증하는 테스트가 아닙니다.

[Cloudflare 배포·롤백 안내](../docs/LANDING-HOSTING.md)
