# 랜딩 호스팅

공개 URL: **https://study-lens.no-money-do-you-have-money.com/**

Questionable Hires와 같은 macOS LaunchAgent + Cloudflare Tunnel 방식입니다.
StudyLens 전용 origin(기본 포트 **4181**), 터널 `studylens-landing`, 서비스
`com.studylens-landing.web` / `com.studylens-landing.tunnel`을 사용합니다.

## 배포

macOS, Python 3.9 이상, `cloudflared`, 기존 `cloudflared tunnel login` 인증,
로그인한 사용자 세션이 필요합니다. 변경 사항을 커밋한 뒤:

```sh
python3 -B scripts/deploy_landing_mac.py
```

이 명령은 공개 origin으로 정적 파일을 빌드하고 별도 날짜별 release에 복사한 뒤,
`current`를 원자적으로 바꿉니다. 로컬 `/_health`에서 앱 ID와 커밋을 확인한 뒤
전용 터널과 DNS route를 만들거나 재사용하고, 공개 HTTPS에서도 같은 커밋을 확인합니다.
기존 DNS 레코드는 덮어쓰지 않습니다. 다른 서비스의 터널·포트·설정을 바꾸지 않습니다.

실행 파일·release·중간 배포 상태는
`~/Library/Application Support/studylens-landing/`, 로그는
`~/Library/Logs/studylens-landing/`, Cloudflare 인증은 `~/.cloudflared/`에 있습니다.
인증 파일은 저장소와 공개 웹 디렉터리에 들어가지 않습니다.

```sh
curl -fsS https://study-lens.no-money-do-you-have-money.com/_health
launchctl print "gui/$(id -u)/com.studylens-landing.web"
launchctl print "gui/$(id -u)/com.studylens-landing.tunnel"
```

공개 확인이 실패하면 배포는 미완료로 보고되며, 중간 상태를 보존합니다.
터널 로그를 확인한 뒤 같은 명령으로 재시도하세요. 새로운 호스트명은 macOS의
negative DNS 캐시에 남을 수 있어 배포 검증은 Cloudflare DNS-over-HTTPS를 사용합니다.

## 롤백

```sh
python3 -B scripts/deploy_landing_mac.py --rollback
```

이전 release는 보존합니다. 로컬 origin 시작에 실패하면 이전 origin으로 복구합니다.
별도 스냅샷이 없는 최초 배포에서는 롤백 대상이 없습니다.

## 운영 조건

LaunchAgent는 로그인 시 시작하고 프로세스가 종료되면 재시작합니다.
**이 Mac이 켜져 있고 인터넷에 연결되어 있어야 사이트가 열립니다.** Cloudflare는
이 Mac의 정적 origin으로 연결합니다. [Cloudflare macOS 서비스 안내](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/as-a-service/macos/).

정적 origin은 loopback에만 바인딩하고 디렉터리 목록·숨김 파일·경로 이탈을 거부합니다.
페이지와 변경 가능한 자산은 `no-cache`로 재검증하며 자체 스크립트/이미지만 허용합니다.
공개 HTML·OG 이미지 응답 확인은 소셜 플랫폼의 캐시된 미리보기 확인과 다릅니다.
