# Codex Usage

맥 메뉴바에 일반 Codex 계정의 **주간 잔여 비율**을 표시하는 작은 네이티브 앱입니다.

## 사용

- 메뉴바 표시: `Codex 87%` (실제 계정 값에 따라 바뀝니다.)
- 자동 갱신: 1분마다. 잠자기에서 깨어난 뒤에도 조회합니다.
- 표시를 클릭: 최신 사용량을 바로 조회합니다. 팝업 메뉴나 별도 버튼은 없습니다.
- 조회 실패: 마지막 수치를 유지하고 `Codex 87% !`를 표시합니다. 다음 주기에 다시 조회하며, 성공하면 `!`가 사라집니다.
- 최초 조회 전: `Codex --%`. 첫 조회부터 실패하면 `Codex --% !`.
- 로그인 시 자동 실행: macOS 로그인 항목으로 등록합니다.

현재 Mac의 `~/Applications/Codex Usage.app`에 설치되어 있습니다. 종료하려면 활성 상태 보기에서 `CodexUsage`를 선택해 종료하면 됩니다. 자동 실행을 끄려면 시스템 설정 → 일반 → 로그인 항목에서 Codex Usage를 끕니다.

## 조회와 메모리

기존 Codex 로그인과 설치된 Codex CLI의 `account/rateLimits/read`를 사용합니다. API 키를 따로 입력하거나 복사하지 않습니다. 채팅이나 모델 실행을 요청하지 않으며, 한도 초기화 크레딧도 사용하지 않습니다.

주간 한도는 `windowDurationMins == 10080`인 항목으로 구분합니다. 여러 한도가 있으면 `codex` 항목을 사용하고 Spark나 5시간 한도와 섞지 않습니다. 남은 비율은 `100 - usedPercent`를 0~100으로 제한한 정수이며, 소수점이 제공되면 내림합니다.

Swift/AppKit으로 만들었습니다. Electron, WebView, 브라우저 및 상주 Codex CLI를 사용하지 않습니다. 1분 타이머 또는 클릭 시에만 조회용 프로세스를 잠깐 실행하고, 완료·오류·15초 시간 초과 후 정리합니다. 중복 조회는 겹쳐 실행하지 않습니다.

앱 상태는 `~/Library/Application Support/Codex Usage/status.json` 한 파일에 덮어씁니다. 인증 정보나 원본 응답, 대화, 사용량 이력은 저장하지 않습니다. Codex CLI 자체의 내부 상태 관리는 기존 Codex 설치에 따릅니다.

## 빌드

macOS 13 이상과 Swift 개발 도구가 필요합니다. 현재 Mac에 맞춰 Apple Silicon용으로 빌드합니다.

```sh
bash build.sh
bash test.sh
```

`build.sh`는 현재 폴더의 상위 폴더에 `Codex Usage.app`을 만들고 로컬 서명합니다. 새 Mac에서 사용하려면 Codex CLI 설치와 로그인이 필요합니다. 사용자가 직접 만든 로컬 앱이며 App Store 배포나 공증은 하지 않았습니다.

## 상태 확인

```sh
"$HOME/Applications/Codex Usage.app/Contents/MacOS/CodexUsage" --check
"$HOME/Applications/Codex Usage.app/Contents/MacOS/CodexUsage" --status
"$HOME/Applications/Codex Usage.app/Contents/MacOS/CodexUsage" --login-status
```

`--check`는 한 번 조회하고 종료합니다. `--status`는 마지막 상태 기록을 출력하므로 앱 종료 후에는 과거 기록일 수 있습니다.

## 검증

- 릴리스 앱 빌드, 코드 서명 검사 및 전체 Swift 타입 검사 통과.
- 실제 계정 조회, 실행 중인 앱의 1분 주기 갱신, 클릭 갱신 기록 확인.
- macOS 로그인 등록: `enabled`, 시스템 등록 정보에서도 `enabled, allowed` 확인.
- 주간 한도 선택, 잘못된 응답, 오류 후 마지막 값 유지·복구, 조회 시간 초과·하위 프로세스 종료 등 17개 검사 통과.
- 유휴 상태 RSS 약 37MB, 조회 사이 상주 하위 프로세스 없음. 측정 시점에 따라 메모리는 달라질 수 있습니다.
- 사용자 세션을 방해하지 않도록 실제 로그아웃·재부팅은 하지 않았습니다.
