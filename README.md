# AI Usage — macOS 메뉴바 위젯

Claude Code와 Codex CLI의 구독 사용량을 메뉴바에 항상 띄워 둔다.

```
Claude 15%   Codex 38%
```

각 서비스의 **공식 사용량 엔드포인트를 5분마다 조회**해 실제 한도 사용률을 보여주고,
조회가 안 되면 로컬 세션 로그 기반 추정으로 물러난다. 클릭하면 창별 사용률, 리셋까지
남은 시간, 일별 사용량 차트, 모델 비중이 나온다.

---

## 빠른 시작

```bash
# 1) 앱과 CLI를 빌드하고 설치 + 로그인 자동 실행 등록 (등록과 동시에 뜬다)
./scripts/build-app.sh --install --register

# 2) 기준선 산출 (과거 30일 로그 전체 스캔, 최초 1회)
.build/release/usagectl calibrate

# 3) 숫자 확인
.build/release/usagectl status
```

키체인 접근 허용 창은 뜨지 않는다. 서명이나 빌드 순서에 신경 쓸 것도 없다
([키체인을 어떻게 읽는가](#키체인을-어떻게-읽는가) 참고).

로그인할 때 자동 실행하는 것은 `--register`가 한다. **시스템 설정 → 일반 → 로그인
항목은 쓰지 않는다** — 둘을 같이 걸면 메뉴바 아이콘이 두 개 뜰 수 있다
([로그인 시 자동 실행](#로그인-시-자동-실행) 참고).

---

## 로그인 시 자동 실행

`--register`가 `~/Library/LaunchAgents/com.daegun.aiusagebar.plist`를 쓰고
`launchctl bootstrap gui/$(id -u)`로 올린다. 등록과 동시에 앱이 뜨므로 `--launch`는
필요 없다. sudo는 어디에도 필요 없다.

```bash
./scripts/build-app.sh --install --register            # 등록 (몇 번을 돌려도 안전하다)
./scripts/build-app.sh --unregister                    # 해제 (빌드하지 않는다)
launchctl print gui/$(id -u)/com.daegun.aiusagebar     # 상태 확인
```

`--register`는 `--install`을 포함한다. plist에 `/Applications`의 **절대 경로**가
박히기 때문이다 — 저장소 안 `build/`를 등록하면 다음 빌드의 `rm -rf`가 launchd가
실행할 파일을 지워 버린다.

### plist에서 설명이 필요한 것 넷

| 키 | 값 | 이유 |
|---|---|---|
| `ProgramArguments` | 번들 안 실행 파일의 절대 경로 | `open -a`는 앱을 넘기고 곧바로 끝난다. launchd가 추적하던 프로세스가 1초 만에 사라진 것으로 보여 `KeepAlive` 판정이 무너진다 |
| `KeepAlive` | `SuccessfulExit = false` | 드롭다운의 **종료** 버튼(`NSApp.terminate`)은 종료 코드 0으로 끝난다. `true`로 두면 launchd가 그 종료를 즉시 되돌려 버튼이 고장 난 것처럼 보인다. 0이 아닌 종료 — 즉 크래시 — 일 때만 되살린다 |
| `ProcessType` | `Interactive` | 지정하지 않으면 launchd가 CPU와 I/O를 조이는 기본 제한을 건다. 수백 MB 로그를 훑는 앱이라 앱과 같은 대우가 필요하다 |
| `AssociatedBundleIdentifiers` | 앱의 번들 ID | 없으면 로그인 항목 화면에 정체 불명의 항목으로 보인다. 사용자가 그걸 끄면 자동 실행이 조용히 죽는다 |

`SuccessfulExit = false`는 이 앱만의 요령이 아니다. Apple 자신의 GUI 에이전트가 같은
값을 쓴다 — `plutil -p /System/Library/LaunchAgents/com.apple.controlcenter.plist`,
`com.apple.Finder.plist` 둘 다 `KeepAlive.SuccessfulExit = false`다.

여기에는 전제가 하나 있다. 이 앱에는 `applicationShouldTerminate`가 없어 기본값
`terminateNow`이고 `Sources/AIUsageBar` 어디에도 `exit(` 호출이 없다. 그래서 종료
버튼이 정확히 0으로 끝난다. 나중에 `.terminateLater`를 쓰거나
`applicationWillTerminate`에서 크래시가 나면 **그 순간 종료 버튼이 다시 고장 난 것처럼
보인다.**

### 로그인 항목과 겹치면 안 된다

**시스템 설정의 로그인 항목에도 앱을 넣어 두면 로그인 때 아이콘이 두 개 뜰 수 있다.**
방향에 따라 다르다 — LaunchServices(`open`, 로그인 항목)로 띄우면 이미 떠 있는
인스턴스를 활성화하는 쪽으로 가지만(실측으로 확인했다), launchd는 LaunchServices를
조회하지 않고 실행 파일을 직접 `exec`하므로 이미 떠 있어도 하나 더 만든다. 로그인
직후에는 둘이 수백 ms 안에 동시에 출발해 어느 쪽이 먼저인지 정해져 있지 않다. 앱에는
아직 단일 인스턴스 가드가 없어서 두 번째가 스스로 물러나지도 않는다.

로그인 항목 목록은 BTM이 관리해 sudo 없이는 읽을 수 없어 `--register`가 대신 지워 줄
수 없다. 대신 스크립트가 인스턴스 수를 세어 둘 이상이면 pid와 함께 경고한다. 세는
시점은 **시작 직후**, 즉 아무것도 죽이기 전이다 — `--install`과 `--register`는 각각
기존 인스턴스를 `pkill`로 정리하므로 그 뒤에서 세면 언제나 한 개로 보인다.
`--launch`는 띄운 직후에 한 번 더 세서, 방금 만들어진 중복까지 본다.

### 자잘한 규칙

- **앱을 지우기 전에 `--unregister`.** 안 그러면 launchd가 없는 실행 파일을 10초마다
  다시 띄우려 들고 스스로 포기하지 않는다. 스크립트는 돌 때마다 등록된 경로를 확인해
  이 상태면 경고한다.
- **`--install`은 `--register` 없이도 잡을 잠깐 내렸다 올린다.** launchd는 경로가
  아니라 PID를 추적하므로, 돌고 있는 채로 번들을 지워도 옛 프로세스가 지워진 파일로
  계속 돌고 launchd는 그걸 정상으로 본다 — "설치했는데 예전 버전이 그대로 돈다"가
  된다. 그렇다고 `pkill`로 죽이면 그 SIGTERM이 "비정상 종료"로 읽혀 방금 지운 옛
  바이너리가 되살아난다.
- **등록된 상태의 `--launch`는 `open`이 아니라 `launchctl kickstart -k`로 간다.**
  같은 이유다.
- **종료 버튼으로 끈 뒤 로그아웃 없이 다시 켜려면**
  `launchctl kickstart gui/$(id -u)/com.daegun.aiusagebar`.
- **`--register`를 다시 돌리면 plist를 통째로 덮어쓴다.** 손으로 넣은 수정은 남지
  않는다. 값을 바꾸려면 `scripts/build-app.sh`를 고친다.
- **sudo로 돌리면 스크립트가 거부한다.** root로 등록하면 plist가 `/var/root`에 깔리고
  `gui/0`에 붙어 사용자에게 아무 효과가 없다 — "등록 완료"를 찍고도 앱이 안 뜨는, 가장
  진단하기 어려운 실패다.
- 로그는 `~/Library/Logs/AIUsageBar.stdout.log`와 `.stderr.log`다. 등록했는데 메뉴바에
  안 뜨면 여기와 `launchctl print gui/$(id -u)/com.daegun.aiusagebar`를 먼저 본다.

---

## 데이터 출처

한도 사용률과 토큰 집계는 서로 다른 곳에서 온다.

| 데이터 | 출처 |
|---|---|
| **Claude 한도 사용률** | `GET https://api.anthropic.com/api/oauth/usage` — Claude Code의 `/usage`가 쓰는 경로 |
| **Codex 한도 사용률** | `GET https://chatgpt.com/backend-api/wham/usage` |
| **토큰량 · 일별 차트 · 모델 비중** | 로컬 세션 로그 (`~/.claude/projects/**`, `~/.codex/sessions/**`) |

인증에는 Claude Code와 Codex가 로그인할 때 저장한 OAuth 토큰을 **읽기만** 해서 쓴다
(키체인 `Claude Code-credentials`, `~/.codex/auth.json`). 토큰을 갱신하지는 않는다 —
refresh token을 회전시키면 각 도구 자신의 세션이 깨질 수 있다. 이 원칙은 아래에서 한 번 더
중요해진다. 키체인 접근이 유지되는 것 자체가 **Claude Code 자신의 쓰기**에 기대고 있다.

### 키체인을 어떻게 읽는가

Claude 토큰은 **다른 앱(Claude Code)이 만든** 로그인 키체인 항목이다. 앱이
`SecItemCopyMatching`으로 직접 읽으면 macOS가 접근 허용 창을 띄우는데, **이 창은
"항상 허용"으로 잠재울 수 없다.** 그래서 직접 읽지 않고 `/usr/bin/security`를 자식
프로세스로 띄운다.

```bash
security find-generic-password -s "Claude Code-credentials" -a "$USER" -w
```

키체인 접근 판정의 대상은 앱이 아니라 **호출한 프로세스**다. `/usr/bin/security`는 항목의
ACL에 이미 들어 있고(`identifier "com.apple.security" and anchor apple`, 상태 `OK`),
아래에서 설명할 partition 검사도 통과한다.

#### 왜 직접 읽기로는 창을 없앨 수 없나

macOS는 키체인 접근을 **두 단계로** 판정한다. ACL의 applications 목록을 통과해도 그와
별개인 **partition list**에서 다시 걸린다.

```
entry 1:
    applications (11):
        0: /Applications/AIUsageBar.app (OK)
            requirement: identifier "com.daegun.aiusagebar" and certificate leaf = H"56fcfc13..."
        …
       10: /usr/bin/security (OK)
            requirement: identifier "com.apple.security" and anchor apple
entry 3:
    authorizations (1): partition_id
    description: apple-tool:            ← 승인 때 박혔던 앱 cdhash가 지워져 있다
```

"항상 허용"을 누르면 ACL에는 designated requirement가 들어가지만, partition list에는
**승인하던 순간 바이너리의 cdhash**가 박힌다. 그리고 **Claude Code는 토큰을 갱신할 때마다
`security`로 이 항목을 덮어쓴다**(`security -i`에 `add-generic-password -U`를 먹인다).
그 쓰기가 partition list를 쓰는 도구의 파티션인 `apple-tool:` 하나로 리셋하면서, 등록돼
있던 cdhash를 지운다.

그래서 앱의 서명을 어떻게 안정시켜도 창은 **토큰 갱신 주기마다** 되돌아온다. 자체 서명
인증서로 requirement를 인증서 기준으로 고정해도, 빌드할 때마다 새 cdhash를 partition
list에 등록해도 마찬가지다 — 자체 서명 인증서에는 팀 ID가 없어 재빌드에도 안 변하는
`teamid:` 항목을 쓸 수도 없다.

이 경우의 창에는 "허용/거부" 버튼만이 아니라 **암호 입력란이 같이 있다.** partition을 고쳐
쓰려면 키체인을 열어야 하기 때문이고, 순수한 ACL 미등록과 구별되는 표식이다.

#### 거꾸로, 그래서 이 방식은 자가 복구된다

같은 쓰기가 반대로 작용한다. Claude Code가 항목을 덮어쓸 때마다 ACL에
`/usr/bin/security (OK)`를, partition list에 `apple-tool:`을 **다시 심어 준다.**
우리가 관리해야 할 빌드 시점 상태가 하나도 없다.

- 앱의 서명 신원은 키체인 판정에 **참여하지 않는다.** ad-hoc으로 서명하든, `usagectl`을
  `swift build`로 따로 빌드하든, `codesign`을 다시 걸든 접근이 깨지지 않는다.
- 조회는 항목이 1,000개 넘게 쌓인 키체인에서도 **16ms**에 돌아온다(10회 중앙값).

#### 정직한 단서

이 방법이 통한다는 것은 곧 **같은 사용자로 도는 어떤 코드든 `security` 한 줄로 이 토큰을
읽을 수 있다**는 뜻이다. 새로 열리는 권한은 없다 — 이미 열려 있던 문으로 들어갈 뿐이다.
키체인 ACL은 동일 사용자 코드에 대한 기밀성 경계가 아니었다. (Codex 토큰은
`~/.codex/auth.json` 평문 파일이라 애초에 이 층이 없다.)

토큰은 파이프로만 오간다. 인자로 넘어가는 것은 서비스 이름과 계정 이름뿐이라 `ps`에 토큰이
보이지 않고, 셸을 거치지 않고 절대 경로로 실행하므로 PATH에 심어진 가짜 `security`에
속지 않는다.

#### 예전 방식에서 넘어왔다면

예전에는 `scripts/create-signing-cert.sh`(지금은 저장소에 없다. 마지막 버전은
`git show 0747acb:scripts/create-signing-cert.sh`)가 자체 서명 인증서를 만들었다. 그 인증서는
더 이상 쓰이지 않지만, 스크립트를 지워도 **개인키는 로그인 키체인에 남는다.** 그 키로 서명한
아무 바이너리나 앱과 똑같은 designated requirement를 갖게 되므로 지우는 편이 낫다.

```bash
security delete-identity -c "AIUsageBar Self Signed"
```

새 빌드를 설치한 **뒤에** 실행할 것(그 인증서로 서명된 앱이 아직 돌고 있으면 서명이 깨진다).
키체인 쓰기지만 실제로는 승인 창 없이 즉시 끝났다. 인증서와 개인키가 함께 사라지므로 그 키의
ACL과 "접근하려면 확인" 설정도 같이 없어진다. 신뢰 설정은 `add-trusted-cert`로 걸어 뒀더라도
가리킬 인증서가 없어져 남지 않는다(`security dump-trust-settings`로 확인 가능).

항목에 남는 것이 둘 있는데 **둘 다 건드릴 필요가 없다.**

**ACL의 옛 AIUsageBar / usagectl 엔트리** — "항상 허용"을 누를 때마다 쌓인 것으로, 재빌드마다
cdhash가 바뀌어 여러 개가 된다. 지금은 **두 겹으로 죽어 있다.** requirement 검증이 실패하고
(`status -2147415734`), 설령 통과해도 partition list에서 다시 걸린다. 실제로 확인해 보면
`swift-frontend`처럼 requirement가 `(OK)`인 항목조차 읽지 못한다.

```swift
SecKeychainSetUserInteractionAllowed(false)   // 창이 뜰 수 없게 막고 확인한다
// … SecItemCopyMatching → status = -25293 (errSecAuthFailed)
```

지우는 방법이 없지는 않다 — `security dump-keychain -i`가 대화형 ACL 편집 모드다. 다만 항목을
지정하는 옵션이 없어 키체인 전체(수백 개)를 하나씩 훑어야 하고, 키체인 접근.app으로 편집하면
그 쓰기가 partition list를 편집 도구의 파티션으로 리셋해 `apple-tool:`을 날릴 수 있다. 얻는 것이
없는데 현재 읽기 경로를 깨뜨릴 위험만 있다.

**partition list에 박힌 옛 cdhash** — 이건 **저절로 사라진다.** Claude Code가 다음 토큰 갱신 때
항목을 덮어쓰면서 partition list를 `apple-tool:` 하나로 리셋하기 때문이다. 창이 되돌아오게 만들던
바로 그 동작이 여기서는 청소부 역할을 한다. 굳이 `set-generic-password-partition-list`로 손대면
로그인 키체인 암호를 입력해야 하고, `apple-tool:`을 빠뜨리면 실시간 조회가 통째로 멈춘다.

#### 그래도 키체인은 덜 두드린다

조회는 5분마다지만 키체인은 그때마다 읽지 않는다 — 받은 토큰을 만료 시각까지 메모리에
들고 있다가, 만료 1분 전에만 다시 읽는다(실제로는 Claude Code의 토큰 갱신 주기와 같다).
서버가 토큰을 거부하면(401/403) 그때는 캐시를 버리고 곧바로 다시 읽는다.

창이 없어졌어도 **백오프는 남겨 뒀다.** 로그인 키체인이 잠겨 있으면 이번엔 `security` 쪽이
잠금 해제 창을 띄우고 무한정 기다린다. 그래서 조회가 10초를 넘기면 자식 프로세스를 끊고
30분간 물러난다 — 5분마다 그 창을 다시 띄우면 없애려던 문제가 형태만 바꿔 되돌아온다.
드롭다운의 **갱신** 버튼이 5분 스로틀과 30분 백오프를 모두 걷어내고 즉시 다시 시도한다.

### 폴백 3단계

공개 문서화된 API가 아니므로 언제든 바뀔 수 있다. 그래서 조용히 0을 표시하는 대신
단계적으로 물러나고, **어느 단계인지 항상 UI에 밝힌다.**

1. **실시간** (초록 점) — 방금 조회한 실제 한도 사용률
2. **마지막 관측** (배지 + 기준 시각) — 조회에 실패해 직전 실측값을 재사용 중
3. **추정** (배지) — 로컬 로그를 기준선으로 환산한 값. 공식 한도가 아니다

토큰 만료로 실패하면 해당 도구를 한 번 실행하면 토큰이 갱신되어 다시 붙는다.
설정에서 실시간 조회를 끄면 3단계만 쓴다.

### 기준선 (추정 단계에서만 쓰임)

로컬 로그에는 "한도 대비 몇 %"가 없다. 그래서 과거 실사용 피크를 기준선으로 삼아 환산한다.
한도에 부딪힌 적이 있다면 그 피크가 곧 실질 한도이고, 없더라도 "평소 대비 지금 얼마나 쓰고
있나"는 정확하다.

기준선은 `usagectl calibrate`로 산출하고, 설정에서 직접 수정할 수 있다. 자동 캘리브레이션을
켜두면 새 피크가 나올 때마다 기준선이 올라간다(실시간 값이 있을 때는 건드리지 않는다).

---

## 중복 제거가 필수인 이유

Claude Code는 세션 재개와 컴팩션 때 **이전 메시지를 로그에 다시 기록한다.** 실측하면
32일치 원본 53,018개 레코드 중 고유한 것은 22,379개 — 그냥 합산하면 사용량이 **2.4배**
부풀려진다. `(requestId, message.id)` 조합으로 걸러낸다.

```bash
.build/release/usagectl debug --dedup
```

---

## 가중 토큰

한도 소진량을 한 축으로 비교하려고, 토큰을 "Opus 입력 토큰 상당"으로 환산한다.
공개 요금표(per MTok)에 비례한다.

| 컴포넌트 | 배수 | | 모델 | 계수 |
|---|---|---|---|---|
| 입력 | 1.0 | | Fable 5 ($10/$50) | 2.0 |
| 출력 | 5.0 | | Opus 5 ($5/$25) | 1.0 |
| 캐시 쓰기 (5분 TTL) | 1.25 | | Sonnet 5 ($3/$15) | 0.6 |
| 캐시 쓰기 (1시간 TTL) | 2.0 | | Haiku 4.5 ($1/$5) | 0.2 |
| 캐시 읽기 | 0.1 | | 미지의 모델 | 1.0 |

모든 모델에서 출력/입력 비율이 5배로 같아서 출력 배수는 모델과 무관하다.

---

## 5시간 블록

Claude 한도는 롤링 5시간이 아니라 **첫 메시지에서 시작해 5시간 뒤 리셋되는 블록**으로
동작한다. 블록은 시작 시각을 정시로 내림하고, 5시간이 지나거나 5시간 이상 공백이 생기면
새로 연다. 기준선도 **같은 알고리즘**으로 뽑아야 단위가 맞으므로 캘리브레이션이 이 블록의
최댓값을 쓴다.

---

## 성능

전체 로그는 3,160개 파일 / 489MB지만 매번 다 읽지 않는다. 파일별로 `(크기, mtime, 오프셋)`을
캐시해 **추가된 바이트만** 파싱한다.

| 상황 | 소요 |
|---|---|
| 최초 전체 스캔 (8일 보관) | ~2.1초 |
| 캘리브레이션 (30일 전체) | ~3초 |
| 증분 갱신 | **~110ms** (프로세스 시작 포함) |

캐시 저장은 30초 간격으로 스로틀링한다. 캐시가 조금 뒤처져도 다음 실행에서 앞선 오프셋부터
다시 읽고 중복 제거가 처리하므로 안전하다.

**실시간 조회는 화면 갱신을 막지 않는다.** 백그라운드로 던져두고 직전 결과로 즉시 그린 뒤,
응답이 오면 다시 그린다. 막는 쪽은 키체인이 아니라 네트워크다 — 키체인 읽기는 16ms로 싸고,
`usagectl status` 한 번의 갱신 165ms 중 나머지가 두 서비스의 HTTP 조회다.

---

## 구조

```
Sources/
├── UsageCore/          UI 의존성 없는 순수 로직 (CLI와 앱이 공유)
│   ├── NDJSONScanner   증분 리더 + 파일 탐색
│   ├── ClaudeCodeProvider  dedup → 5시간 블록 집계
│   ├── CodexProvider   rate_limits 추출 + 만료 판정
│   ├── SessionBlock    5시간 블록 알고리즘
│   ├── TokenWeight     모델 계수 / 가중 토큰
│   ├── Baseline        기준선 캘리브레이션
│   └── UsageMonitor    서비스 통합 + 자동 캘리브레이션
├── usagectl/           숫자 검증용 CLI
└── AIUsageBar/         메뉴바 앱 (NSStatusItem + SwiftUI)
```

상태 저장 위치: `~/Library/Application Support/AIUsageBar/`

---

## CLI

```
usagectl status              현재 사용량 요약
usagectl calibrate [--days N]  과거 로그로 기준선 산출 (기본 30일)
usagectl debug [--dedup]     스캔 통계와 중복 제거 검증
usagectl config              현재 설정 출력
usagectl reset               캐시 삭제 후 전체 재스캔
```

---

## 개발

```bash
swift build
swift build -c release

# 테스트에는 XCTest가 필요한데 Command Line Tools에는 없다.
# xcode-select를 바꾸지 않고 Xcode 툴체인만 빌려 쓴다.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Xcode 프로젝트는 없다. SwiftPM만으로 `.app` 번들까지 만든다 (`scripts/build-app.sh`).

---

## 알려진 한계

- **사용량 엔드포인트는 공개 문서화된 API가 아니다.** 예고 없이 바뀔 수 있고, 그러면
  추정 단계로 물러난다.
- **토큰이 만료되면 실시간 조회가 멈춘다.** 토큰 갱신은 일부러 하지 않는다 —
  refresh token을 회전시키면 Claude Code나 Codex 자신의 세션이 깨질 수 있다.
  해당 도구를 한 번 실행하면 다시 붙는다.
- **Gemini 등 구독형 서비스는 지원하지 않는다.** 공개된 사용량 조회 경로가 없다.
- 로그 포맷이 바뀌면 파서를 고쳐야 한다. 파싱에 실패하면 조용히 0을 표시하지
  않고 메뉴바에 `!`를 띄운다.
- **로그인 키체인이 잠겨 있으면 실시간 조회가 멈춘다.** `security`가 잠금 해제 창을 띄우고
  기다리기 때문이다. 10초 뒤 끊고 30분 물러난다. 이때 표시되는 메시지는 "키체인이 응답하지
  않아 조회를 중단했습니다"이고, 잠금을 풀고 드롭다운의 **갱신**을 누르면 바로 붙는다.
- **"Claude Code 로그인 정보를 찾지 못했습니다"는 여러 원인을 뭉갠다.** `security`는 항목
  없음·키체인 파일 없음·홈 경로 어긋남을 모두 같은 종료 코드(44)로 낸다. 대개는 Claude Code
  로그아웃 상태다.
- **로그인 키체인에 `Claude Code-credentials-<해시>` 항목이 수백~천 단위로 쌓여 있을 수 있다**
  (2026-08 실측 기준 1,000개 이상). Claude Code가 남기는 것으로, 이 앱은 `-s`로 접미사 없는
  `Claude Code-credentials`에 정확히 일치하는 항목만 읽으므로 동작에는 영향이 없다. 그만큼
  쌓여도 조회는 16ms에 돌아온다.
- **LaunchAgent와 로그인 항목을 동시에 걸면 메뉴바 아이콘이 두 개 뜰 수 있다.** 앱에
  단일 인스턴스 가드가 없고, 로그인 항목 목록은 sudo 없이 읽을 수 없어 스크립트가
  대신 정리해 줄 수도 없다. 지금은 실행 후 인스턴스 수를 세어 경고하는 것이 전부다.
- **자동 실행 등록은 GUI 로그인 세션에서만 즉시 반영된다.** SSH 세션에는 `gui/$UID`
  도메인이 없어(`launchctl print`가 112로 끝난다) 그 자리에서 올리지 못한다. plist는
  설치되므로 다음 로그인 때 올라온다 — 스크립트는 그 사실을 알리고 성공으로 끝낸다.
- **`~/Library/Logs/AIUsageBar.*.log`는 회전하지 않는다.** 앱이 직접 쓰는 것은 없어
  평소엔 비어 있지만, 크래시 루프에 빠지면 launchd가 10초마다 되살리며 재기동 로그가
  쌓인다. 줄이는 것은 지금 수동이다 — 커졌으면 직접 비운다.
- **한 대를 여러 관리자 계정이 쓰면 `/Applications`는 공유지만 LaunchAgent는 계정마다
  따로다.** A가 등록해 둔 상태에서 B가 `--install`을 돌리면 B는 A의 잡을 볼 수도 내릴
  수도 없어, A의 세션에서 옛 바이너리가 계속 돈다. 스크립트가 막을 수 없다.
