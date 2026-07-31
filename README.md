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
# 1) 기준선 산출 (과거 30일 로그 전체 스캔, 최초 1회)
swift build -c release
.build/release/usagectl calibrate

# 2) 숫자 확인
.build/release/usagectl status

# 3) 앱 빌드 + 설치 + 실행
./scripts/build-app.sh --install --launch
```

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
- 앱을 다시 빌드하면 ad-hoc 서명이 바뀌어 키체인이 접근 허용을 다시 물을 수 있다.
