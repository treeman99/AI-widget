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
# 1) 서명용 인증서 생성 (최초 1회) — 키체인 접근 창이 반복해서 뜨는 것을 막는다
./scripts/create-signing-cert.sh

# 2) 앱과 CLI를 빌드하고 서명 + 설치 + 실행
./scripts/build-app.sh --install --launch

# 3) 기준선 산출 (과거 30일 로그 전체 스캔, 최초 1회)
.build/release/usagectl calibrate

# 4) 숫자 확인
.build/release/usagectl status
```

순서가 중요하다. `build-app.sh`가 앱과 `usagectl`을 **함께** 빌드하고 서명하기 때문에,
CLI를 먼저 쓰려고 `swift build`를 따로 돌리면 ad-hoc 서명 상태로 실행되어 키체인 창이
한 번 더 뜬다.

창은 두 종류가 뜬다. 헷갈리기 쉬우니 구분해 두자.

| 창 | 언제 | 눌러야 할 것 |
|---|---|---|
| "codesign이 키 'AIUsageBar Self Signed'를 사용하려 합니다" | 빌드할 때 | **허용** (항상 허용은 권장하지 않음 — 아래 참고) |
| "AI Usage이(가) 'Claude Code-credentials'를 사용하려고 합니다" | 앱이 사용량을 읽을 때 | **항상 허용** |

두 번째 창은 한 번만 누르면 되고, 이후 재빌드해도 다시 묻지 않는다
([키체인 접근 창](#키체인-접근-창) 참고).

로그인할 때 자동 실행하려면 **시스템 설정 → 일반 → 로그인 항목**에 `AIUsageBar.app`을 추가한다.

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
refresh token을 회전시키면 각 도구 자신의 세션이 깨질 수 있다.

### 키체인 접근 창

Claude 토큰은 **다른 앱(Claude Code)이 만든** 키체인 항목이라, macOS가 접근 허용 창을 띄운다.
한 번 "항상 허용"을 누르면 끝나야 하는데, 조건이 하나 있다 — **앱의 서명이 안정적이어야 한다.**

"항상 허용"은 앱의 designated requirement를 신뢰 목록에 저장한다. ad-hoc 서명
(`codesign --sign -`)은 이 requirement가 **바이너리 해시 그 자체**다.

```
designated => cdhash H"285d8d28..."
```

그래서 코드를 한 줄만 고쳐 다시 빌드해도 해시가 바뀌고, 키체인은 완전히 다른 앱으로 보아
허용 기록을 버린다. 창이 계속 되돌아오는 이유다. `scripts/create-signing-cert.sh`가 만드는
자체 서명 인증서로 서명하면 requirement가 인증서 기준이 된다.

```
designated => identifier "com.daegun.aiusagebar" and certificate leaf = H"f8dad562..."
```

바이너리가 바뀌어도 인증서는 그대로이므로 허용이 유지된다. Developer ID로 서명된 앱이
업데이트 후에도 다시 묻지 않는 것과 같은 원리다.

#### 그런데 서명만으로는 부족하다 — partition list

인증서로 서명해 놓고도 창이 계속 뜬다면, 남은 원인은 거의 항상 이쪽이다. macOS는 키체인
접근을 **두 단계로** 판정하는데, ACL의 applications 목록을 통과해도 그와 별개인
**partition list**에서 다시 걸린다.

```
entry 1:                                     ← ACL: 인증서 기준이라 재빌드에도 유지된다
    applications (11):
        0: /Applications/AIUsageBar.app (OK)
            requirement: identifier "com.daegun.aiusagebar" and certificate leaf = H"56fcfc13..."
entry 3:                                     ← partition list: cdhash 라서 재빌드하면 깨진다
    authorizations (1): partition_id
    description: apple-tool:, cdhash:629e71d1...
```

"항상 허용"을 누르면 macOS는 ACL에는 designated requirement(인증서 기준)를 넣지만,
partition list에는 **승인하던 순간 바이너리의 cdhash**를 박아 넣는다. 그래서 다시 빌드하면
ACL은 여전히 맞는데 partition이 어긋나 창이 되돌아온다. 이 경우의 창에는 "허용/거부"
버튼만이 아니라 **암호 입력란이 같이 있다** — partition을 고쳐 쓰려면 키체인을 열어야
하기 때문이고, 순수한 ACL 미등록과 구별되는 표식이다.

자체 서명 인증서에는 팀 ID가 없어서 재빌드에도 안 변하는 `teamid:` 항목을 쓸 수 없다.
그래서 `build-app.sh`가 서명 직후 새 cdhash를 직접 등록한다.

```bash
security set-generic-password-partition-list \
  -S "apple:,apple-tool:,cdhash:<앱>,cdhash:<usagectl>" \
  -s "Claude Code-credentials" -a "$USER" ~/Library/Keychains/login.keychain-db
```

이때 키체인 암호를 한 번 묻는다. 주의할 점은 이 명령이 암호를 **GUI 창이 아니라 tty에서**
받는다는 것이다(`password to unlock …:`). 그래서 터미널 없이 돌리면 빈 값이 들어가 조용히
실패하므로, 반드시 터미널에서 실행하거나 `KEYCHAIN_PASSWORD`로 넘겨야 한다.

```bash
./scripts/build-app.sh --install --launch          # 터미널에서 암호 입력
KEYCHAIN_PASSWORD='…' ./scripts/build-app.sh --install --launch   # 히스토리에 남는 점 감안
```

#### 대가: 서명 키를 지켜야 한다

이 requirement에는 함정이 있다. `identifier`도 `certificate leaf` 해시도 **서명하는 쪽이
정하는 값**이다. 그래서 개인키를 쓸 수 있는 프로세스는 아무 바이너리에나 이 앱과 똑같은
requirement를 붙일 수 있고, 그 위조본은 사용자가 앱에 눌러 준 "항상 허용"을 그대로
물려받아 Claude 토큰을 읽는다.

```bash
# 개인키에 무프롬프트로 접근할 수 있다면 이게 통과한다
cp /bin/echo /tmp/forge
codesign -f -s "AIUsageBar Self Signed" -i com.daegun.aiusagebar /tmp/forge
# → /tmp/forge 의 designated requirement가 앱과 한 글자도 다르지 않다
```

ad-hoc 서명은 requirement가 cdhash라 이런 위조가 애초에 불가능했다. 편의를 얻는 대신
그 성질을 버리는 것이므로, **개인키 보호가 이 방식의 전제 조건**이다.

문제는 **명령행만으로는 그 보호를 걸 수 없다는 것**이다. `security import`에
`-T /usr/bin/codesign`을 주지 않아도 macOS는 키를 무프롬프트로 내주고,
`set-key-partition-list`는 partition만 건드리는데 codesign은 Apple 서명이라 어차피
`apple:` partition을 통과한다. 기존 키의 ACL을 편집하는 CLI 명령은 없다.

그래서 `create-signing-cert.sh`는 생성 직후 **실제로 위조를 시도해 보고**, 뚫리면
GUI 설정을 안내한다. 키체인 접근.app에서 한 번만 하면 된다.

> 로그인 키체인 → "나의 인증서" 탭 → `AIUsageBar Self Signed` 펼치기 → 개인 키 더블클릭
> → **접근 제어** 탭 → "이 항목에 접근하려면 확인" 체크 → 저장

이후 빌드할 때마다 승인 창이 뜬다. 여기서 **"항상 허용"을 누르면 이 보호가 도로
풀린다.** "허용"을 눌러야 그 빌드에만 적용된다.

이 설정을 할 생각이 없다면 인증서 방식을 쓰지 않는 편이 낫다. ad-hoc이 보안상 더 강하다
(대신 재빌드마다 키체인 창이 뜬다).

```bash
security delete-identity -c "AIUsageBar Self Signed"
```

(참고로 Codex 토큰은 `~/.codex/auth.json` 평문 파일이라 원래부터 이 보호가 없다.
키체인 ACL로 보호되는 건 Claude 토큰뿐이다.)

여기에 더해 **키체인을 두드리는 횟수 자체를 줄인다.** 조회는 5분마다지만 키체인은 그때마다
읽지 않는다 — 받은 토큰을 만료 시각까지 메모리에 들고 있다가, 만료 1분 전에만 다시 읽는다
(실제로는 Claude Code의 토큰 갱신 주기와 같다). 사용자가 창을 닫으면 30분간 다시 묻지
않는다. 서버가 토큰을 거부하면(401/403) 그때는 캐시를 버리고 곧바로 다시 읽는다.

실수로 "거부"를 눌렀다면 30분을 기다릴 필요 없다. 드롭다운의 **갱신** 버튼이 5분 스로틀과
30분 백오프를 모두 걷어내고 즉시 다시 시도한다.

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
응답이 오면 다시 그린다. 프로세스당 첫 키체인 접근에 4~5초가 걸리기 때문에(서명 검증)
동기로 기다리면 시작할 때 UI가 멈춘다.

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
- **서명 인증서를 지우거나 다시 만들면** 키체인이 접근 허용을 한 번 더 묻는다. 인증서가
  바뀌면 requirement도 바뀌기 때문이다. `create-signing-cert.sh`는 이미 인증서가 있으면
  새로 만들지 않는다.
- **`usagectl`을 `swift build`로 따로 빌드하면 ad-hoc 서명으로 되돌아간다.** SwiftPM이
  링크할 때마다 서명을 새로 붙이기 때문이다. 그러면 CLI에 대해서만 키체인 창이 다시 뜬다.
  `scripts/build-app.sh`가 앱과 CLI를 함께 빌드하고 서명하므로 그쪽을 쓰면 된다.
- **서명 키를 "항상 허용"으로 열어 두면 위조가 가능해진다.** 위의
  [대가: 서명 키를 지켜야 한다](#대가-서명-키를-지켜야-한다) 참고.
- Claude Code가 토큰을 갱신할 때 키체인 항목을 통째로 다시 쓰면 항목에 걸린 허용 목록이
  초기화될 수 있다. 이때는 서명과 무관하게 창이 한 번 더 뜬다.
- **`build-app.sh`를 거치지 않고 `codesign`만 다시 걸면 partition list가 낡는다.**
  ACL은 인증서 기준이라 통과하지만 partition은 cdhash 기준이라 어긋난다
  ([partition list](#그런데-서명만으로는-부족하다--partition-list) 참고). 지금 상태는
  이렇게 확인한다.

  ```bash
  # 앱의 현재 cdhash
  codesign -dv --verbose=4 /Applications/AIUsageBar.app 2>&1 | grep '^CDHash='
  # 키체인에 등록된 partition list
  security dump-keychain -a ~/Library/Keychains/login.keychain-db \
    | grep -A2 'partition_id' | grep cdhash
  ```

  두 해시가 다르면 다음 실행에서 창이 뜬다.
- **로그인 키체인에 `Claude Code-credentials-<해시>` 항목이 수백 개 쌓여 있을 수 있다.**
  Claude Code가 남기는 것으로, 이 앱은 접미사 없는 `Claude Code-credentials`만 읽으므로
  동작에는 영향이 없다. 다만 `security dump-keychain` 출력이 그만큼 길어진다.
