#!/bin/bash
# AIUsageBar.app 번들을 만든다.
#
# Xcode 프로젝트 없이 SwiftPM 산출물을 손으로 감싼다. xcode-select가 Command Line
# Tools를 가리키고 있어도 동작한다(AppKit/SwiftUI는 CLT SDK에 포함돼 있다).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CONFIGURATION="release"
INSTALL=0
LAUNCH=0
REGISTER=0
UNREGISTER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIGURATION="debug" ;;
    --install) INSTALL=1 ;;
    --launch) LAUNCH=1 ;;
    --register) REGISTER=1 ;;
    --unregister) UNREGISTER=1 ;;
    -h|--help)
      cat <<'USAGE'
사용법: scripts/build-app.sh [옵션]

  --debug       디버그 빌드로 번들 생성 (기본: release)
  --install     생성한 앱을 /Applications 로 복사
  --launch      생성한 앱 실행 (등록돼 있으면 launchd 로 재시작)
  --register    로그인 시 자동 실행 등록 (LaunchAgent). --install 을 포함한다
  --unregister  자동 실행 해제 후 종료 (빌드하지 않는다, 단독으로만)

sudo 로 실행하지 않는다. 등록이 root 세션에 걸려 아무 효과가 없다.
USAGE
      exit 0
      ;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
  esac
  shift
done

APP_NAME="AIUsageBar"
BUNDLE="$ROOT/build/$APP_NAME.app"
BINARY="$ROOT/.build/$CONFIGURATION/$APP_NAME"

# ── launchd 등록 대상 ──────────────────────────────────────────────────────
# Label 은 Resources/Info.plist 의 CFBundleIdentifier 와 같은 값으로 둔다. 아래
# plist 의 AssociatedBundleIdentifiers 가 그 사실에 기대고 있다.
LABEL="com.daegun.aiusagebar"
# 도메인은 gui/<uid>. user/<uid> 도 있지만 그쪽은 GUI 로그인 없이도 존재하는
# 도메인이라, 상태 표시줄이 있어야 의미가 있는 이 앱에는 맞지 않는다.
DOMAIN="gui/$(id -u)"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT_PLIST="$AGENT_DIR/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"
STDOUT_LOG="$LOG_DIR/$APP_NAME.stdout.log"
STDERR_LOG="$LOG_DIR/$APP_NAME.stderr.log"
APP_DEST="/Applications/$APP_NAME.app"
SELF="scripts/build-app.sh"
# 이번 실행에서 launchd 가 이미 앱을 띄웠는지. --launch 가 또 띄우지 않게 하는 데 쓴다.
STARTED_BY_LAUNCHD=0

# 설치 스테이징과 plist 렌더가 이 변수 쌍을 함께 쓴다. 성공하면 변수를 비워서
# 청소 대상에서 뺀다. trap 을 여러 군데 걸면 나중에 서로를 조용히 덮어쓴다.
TMP_STAGE=""
TMP_PLIST=""
cleanup_tmp() {
  if [ -n "$TMP_STAGE" ]; then rm -rf "$TMP_STAGE"; fi
  if [ -n "$TMP_PLIST" ]; then rm -f "$TMP_PLIST"; fi
  return 0
}
trap cleanup_tmp EXIT

# sudo 는 "조용히 아무 효과가 없는" 실패를 만든다. $HOME 이 /var/root, uid 가 0 이
# 되어 plist 가 /var/root/Library/LaunchAgents 에 깔리고 gui/0 에 등록된다 —
# 스크립트는 "등록 완료" 를 찍는데 로그인해도 앱이 뜨지 않는다. /Applications 는
# drwxrwxr-x root:admin 이라 관리자 계정이면 sudo 없이 쓸 수 있다. (순수 빌드는
# 건드리지 않는다.)
if [ "$(id -u)" -eq 0 ] && { [ "$INSTALL" -eq 1 ] || [ "$REGISTER" -eq 1 ] || [ "$UNREGISTER" -eq 1 ]; }; then
  echo "sudo 로 실행하지 마세요." >&2
  echo "  LaunchAgent 가 /var/root 에 깔리고 gui/0 에 등록돼 사용자 세션에는 아무 효과가 없습니다." >&2
  echo "  \"등록 완료\" 를 찍고도 로그인 때 앱이 뜨지 않는, 가장 진단하기 어려운 실패입니다." >&2
  exit 1
fi

# 한 번의 실행이 "빌드해서 배치한다" 와 "치운다" 를 동시에 가리키면 순서를 어떻게
# 정해도 설명이 안 된다. --debug 는 무해하므로 통과시킨다.
if [ "$UNREGISTER" -eq 1 ] && { [ "$REGISTER" -eq 1 ] || [ "$INSTALL" -eq 1 ] || [ "$LAUNCH" -eq 1 ]; }; then
  echo "--unregister 는 다른 동작 옵션과 함께 쓸 수 없습니다." >&2
  exit 1
fi

# plist 는 $APP_DEST 의 절대 경로를 박는다. 설치 없이 등록하면 없는 경로를 등록하게
# 되고, launchd 는 spawn 실패를 시스템 로그에만 남기고 조용히 물러난다 — 사용자가
# 보는 것은 "등록됐다는데 로그인해도 안 뜬다" 뿐이다. 그렇다고 하드 에러로 막으면 더
# 나쁜 상태가 생긴다: 빌드는 해 놓고 설치는 안 하면 방금 빌드한 것이 아닌 앱이
# 등록된다. 그래서 조용히가 아니라 한 줄 찍고 승격한다.
if [ "$REGISTER" -eq 1 ] && [ "$INSTALL" -eq 0 ]; then
  INSTALL=1
  echo "▸ --register 는 --install 을 포함합니다 (plist 가 $APP_DEST 를 가리킵니다)"
fi

if [ "$REGISTER" -eq 1 ] && [ "$CONFIGURATION" = "debug" ]; then
  echo "  주의: 디버그 빌드를 로그인마다 뜨는 자리에 등록합니다. plist 만 봐서는 구별되지 않습니다." >&2
fi

# ── launchd 헬퍼 ───────────────────────────────────────────────────────────
#
# 판정은 종료 코드가 아니라 `launchctl print` 로만 한다. print 의 코드는 안정적이다
# — 있음 0 / 서비스 없음 113 / 도메인 없음 112. 반대로 상태를 바꾸는 쪽은 믿을 수
# 없다: bootstrap 은 이미 등록된 잡에 5(Input/output error)를 내는데 5 는 launchd 의
# 포괄 오류라 "이미 있음" 과 "plist 가 잘못됨" 과 "disable 돼 있음" 을 구분해 주지
# 않고, 레거시 load/unload 는 man launchctl 이 못박듯 "will only return a non-zero
# exit code due to improper usage. Otherwise, zero is always returned." 다.
job_loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }
gui_domain_available() { launchctl print "$DOMAIN" >/dev/null 2>&1; }

# bootout 은 SIGTERM 을 보내고 기다리지만, 레이블이 도메인에서 완전히 빠지기 전에
# 곧바로 bootstrap 하면 위의 5 로 실패한다. 에러를 해석하는 대신 실제로 빠졌는지
# 확인한다. 이 잡의 exit timeout 은 5초라, 그 두 배인 10초까지 본다.
job_stop() {
  job_loaded || return 0
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  local i=0
  while [ "$i" -lt 40 ]; do
    job_loaded || return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

# 등록해 둔 채 앱을 지우거나 옮기면 launchd 는 없는 실행 파일을 minimum runtime(10초)
# 간격으로 계속 띄우려 든다. 스스로 포기하지 않고, 실패는 시스템 로그에만 남아 아무
# 신호도 없다. 스크립트를 돌릴 때마다 이 상태를 알려 준다.
warn_stale_agent() {
  [ -f "$AGENT_PLIST" ] || return 0
  local prog
  prog="$(plutil -extract ProgramArguments.0 raw -o - "$AGENT_PLIST" 2>/dev/null || true)"
  [ -n "$prog" ] || return 0
  if [ -x "$prog" ]; then return 0; fi
  echo "경고: 등록된 LaunchAgent 가 없는 실행 파일을 가리킵니다." >&2
  echo "      $prog" >&2
  echo "      launchd 가 10초마다 기동을 재시도하며 계속 실패합니다." >&2
  echo "      정리: $SELF --unregister   /   다시 깔기: $SELF --register" >&2
  return 0
}

# LaunchAgent 와 시스템 설정의 로그인 항목을 동시에 걸어 두면 로그인 순간 둘이 경합해
# 아이콘이 두 개가 될 수 있다. 로그인 항목 목록은 BTM 이 관리해 sudo 없이는 읽을 수
# 없고, System Events 로 들여다보면 사용자 화면에 자동화 권한 창이 뜬다. 스크립트가
# 대신 정리해 줄 수는 없지만 세어서 알릴 수는 있다.
# (pgrep 은 매치가 없으면 1 을 내므로 pipefail 아래서 감싸 준다.)
warn_multiple_instances() {
  local count pids
  count="$( { pgrep -x "$APP_NAME" || true; } | wc -l | tr -d ' ')"
  if [ "${count:-0}" -le 1 ]; then return 0; fi
  pids="$( { pgrep -x "$APP_NAME" || true; } | tr '\n' ' ')"
  echo "  경고: $APP_NAME 이 ${count}개 떠 있습니다 (pid: $pids)"
  echo "        시스템 설정 → 일반 → 로그인 항목 에 이 앱이 남아 있으면 지우세요."
  echo "        LaunchAgent 와 로그인 항목은 서로를 모릅니다. 하나만 씁니다."
  return 0
}

unregister_agent() {
  echo "▸ 자동 실행 해제"

  if gui_domain_available; then
    # 내리기 "전에" 올라와 있었는지 본다. bootout 뒤의 job_loaded 는 "잘 내려갔다" 와
    # "원래 없었다" 를 구분하지 못해서, 등록도 안 된 상태에서 내렸다고 보고하게 된다.
    if job_loaded; then
      # 판정은 job_stop 에 맡긴다. bootout 은 레이블이 도메인에서 완전히 빠지기 전에
      # 돌아오므로, 곧바로 확인하면 멀쩡히 내려간 잡을 "아직 살아 있다" 고 잘못
      # 보고한다 — 등록 경로에서 이미 같은 경합을 대기 루프로 막고 있다.
      if job_stop; then
        echo "  내림: $DOMAIN/$LABEL (앱도 함께 내려갑니다)"
      else
        echo "  경고: 잡이 아직 살아 있습니다: $DOMAIN/$LABEL" >&2
      fi
    else
      echo "  올라와 있는 잡이 없습니다: $DOMAIN/$LABEL"
    fi
  else
    echo "  GUI 세션이 아니라 지금 잡을 내리지 못했습니다 (SSH?). 다음 로그인부터는 올라오지 않습니다."
  fi

  if [ -f "$AGENT_PLIST" ]; then
    rm -f "$AGENT_PLIST"
    echo "  제거: $AGENT_PLIST"
  else
    echo "  등록돼 있지 않습니다: $AGENT_PLIST"
  fi

  # 이건 --uninstall 이 아니다. 앱도 로그도 지우지 않는다.
  echo "  앱은 그대로 둡니다: $APP_DEST"
}

register_agent() {
  echo "▸ 자동 실행 등록"

  # 설치가 실패했는데 등록만 성공하는 순서 사고를 막는다. 저장소 안 build/ 를
  # 등록하지 않는 이유도 여기 있다 — 다음 빌드의 rm -rf 가 그 번들을 지우는 순간
  # 좀비 잡이 된다.
  if [ ! -x "$APP_DEST/Contents/MacOS/$APP_NAME" ]; then
    echo "  등록할 앱이 없습니다: $APP_DEST" >&2
    exit 1
  fi

  mkdir -p "$AGENT_DIR" "$LOG_DIR"
  # StandardOutPath/StandardErrorPath 를 열지 못하면 launchd 는 리디렉션 준비
  # 단계에서 실패해 잡이 아예 안 뜬다. 그 실패는 바로 그 로그에 남지 않는 순환이라,
  # 사용자가 보는 것은 "아이콘이 안 뜬다" 뿐이다. 여기서 미리 잡는다.
  for f in "$STDOUT_LOG" "$STDERR_LOG"; do
    if [ -e "$f" ] && [ ! -w "$f" ]; then
      echo "  로그 파일에 쓸 수 없습니다: $f (소유자 $(stat -f %Su "$f"))" >&2
      echo "  이 상태로는 launchd 가 잡을 띄우지 못합니다. 파일을 지우거나 소유자를 고치세요." >&2
      exit 1
    fi
  done

  # 같은 디렉터리에 만들어 mv 를 원자적으로 한다. 살아 있는 plist 를 직접 자르지
  # 않으므로, 중간에 끊겨도 반쪽짜리가 launchd 에 닿지 않는다.
  #
  # 구분자에 따옴표가 없어 $LABEL 등이 풀린다. 확장은 한 번뿐이라 값 안에 $ 가 들어
  # 있어도 다시 스캔되지 않는다. 대신 XML 본문에 백틱을 절대 쓰지 않는다 — 그건
  # 명령 치환으로 실행돼 버린다.
  TMP_PLIST="$(mktemp "$AGENT_DIR/.$LABEL.plist.XXXXXX")"
  cat > "$TMP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  scripts/build-app.sh --register 가 만든 파일이다. 손으로 고쳐도 다음 --register 가
  통째로 덮어쓴다. 값을 바꾸려면 스크립트를 고쳐라.
-->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <!--
    "open -a" 가 아니라 실행 파일을 직접 띄운다. open 은 앱을 넘겨주고 곧바로 끝나므로
    launchd 가 추적하던 프로세스가 1초 만에 사라진 것으로 보이고, 그러면 KeepAlive
    판정이 무너진다. LSUIElement 앱이라 Dock 아이콘 없이 상태 표시줄에만 올라온다.

    절대 경로다. 앱을 옮기거나 지우면 등록만 남고 실행이 조용히 실패한다 —
    scripts/build-app.sh 가 돌 때마다 이 경로를 확인해 경고한다.
  -->
  <key>ProgramArguments</key>
  <array>
    <string>$APP_DEST/Contents/MacOS/$APP_NAME</string>
  </array>

  <!-- 로그인 시 자동 기동 -->
  <key>RunAtLoad</key>
  <true/>

  <!--
    드롭다운의 종료 버튼이 NSApp.terminate 를 부른다
    (Sources/AIUsageBar/StatusItemController.swift 의 onQuit). AppKit 의 terminate:
    는 종료 코드 0 으로 프로세스를 끝낸다. 그래서 KeepAlive 를 그냥 true 로 두면
    launchd 가 그 종료를 즉시 되돌려 종료 버튼이 고장 난 것처럼 보인다.
    SuccessfulExit=false 는 "0 이 아닌 종료일 때만 되살린다" 는 뜻이라, 크래시
    복구는 얻고 의도적 종료는 존중한다.

    전제가 하나 있다: 이 앱에 applicationShouldTerminate 가 없어 기본값
    terminateNow 이고, Sources/AIUsageBar 어디에도 exit( 호출이 없다. 나중에
    .terminateLater 를 쓰거나 applicationWillTerminate 에서 크래시가 나면 종료
    코드가 0 이 아니게 되고, 그 순간 종료 버튼이 다시 고장 난 것처럼 보인다.

    여기에 다른 조건(Crashed 등)을 같이 넣지 말 것 — KeepAlive 딕셔너리의 조건들은
    OR 라서 SuccessfulExit=false 가 무력화된다.
  -->
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>

  <!--
    지정하지 않으면 launchd 가 CPU 와 I/O 를 조이는 기본 제한을 건다 (man
    launchd.plist: "the system will apply light resource limits to the job,
    throttling its CPU usage and I/O bandwidth"). 수백 MB 로그를 증분 스캔하고
    5분마다 HTTP 를 치는 앱이라 앱과 같은 대우가 필요하다.
  -->
  <key>ProcessType</key>
  <string>Interactive</string>

  <!--
    시스템 설정 → 일반 → 로그인 항목 화면에 레이블이 아니라 앱 이름으로 보이게 한다
    (man launchd.plist 가 legacy plist 에 이 키를 넣으라고 적는다). 정체 불명의
    항목으로 보이면 사용자가 그것을 끄고, 그러면 자동 실행이 조용히 죽는다.
  -->
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>$LABEL</string>
  </array>

  <key>StandardOutPath</key>
  <string>$STDOUT_LOG</string>
  <key>StandardErrorPath</key>
  <string>$STDERR_LOG</string>
</dict>
</plist>
PLIST

  if ! plutil -lint "$TMP_PLIST" >/dev/null; then
    echo "  만든 plist 가 형식 오류입니다 — 등록을 중단합니다." >&2
    exit 1
  fi

  # ── 여기서부터가 멱등한 등록 시퀀스다. 순서에 전부 이유가 있다. ──────────

  # 1. 확실히 내린다. 이미 등록된 상태에서 bootstrap 만 다시 부르면 5 로 실패하고,
  #    kickstart 나 enable 로는 대신할 수 없다 — 둘 다 plist 를 다시 읽지 않는다.
  #    --register 는 plist 를 매번 새로 쓰므로 bootstrap 이 반드시 필요하다.
  job_stop || { echo "  기존 등록을 내리지 못했습니다: $DOMAIN/$LABEL" >&2; exit 1; }

  # 2. launchd 밖에서 open 으로 띄워 둔 인스턴스를 정리한다. 잡을 내린 뒤라 KeepAlive
  #    가 되살리지 않는다. 여기서 안 치우면 곧 이어질 bootstrap 의 RunAtLoad 가 두
  #    번째 인스턴스를 만든다.
  pkill -x "$APP_NAME" 2>/dev/null || true

  # 3. 검사를 통과한 것만 제자리로 옮긴다. 그룹/기타 쓰기 권한이 있으면 launchd 가
  #    거부하므로 권한도 여기서 맞춘다.
  chmod 644 "$TMP_PLIST"
  mv "$TMP_PLIST" "$AGENT_PLIST"
  TMP_PLIST=""

  # 4. GUI 도메인이 없으면(SSH 접속 등) 지금 올릴 수는 없다. 하지만 파일은 제자리에
  #    있으니 다음 GUI 로그인 때 launchd 가 올린다. 등록이라는 목적은 달성됐으므로
  #    빌드를 실패시키지 않는다. 다만 "등록 완료" 라고 찍지도 않는다.
  if ! gui_domain_available; then
    echo "  GUI 세션이 아니라 지금은 올리지 못했습니다 (SSH 접속?)."
    echo "  plist 는 설치했습니다 — 다음 로그인부터 자동으로 올라옵니다: $AGENT_PLIST"
    return 0
  fi

  # 5. 예전에 launchctl disable 이나 unload -w 를 한 적이 있으면 그 기록이 재부팅을
  #    넘어 남아 bootstrap 을 막는다 (man launchctl: "Once a service is disabled, it
  #    cannot be loaded in the specified domain until it is once again enabled. This
  #    state persists across boots of the device."). 그 실패도 똑같이 5 로 나와
  #    구분되지 않으니 먼저 푼다. 한 번도 disable 한 적 없으면 무해하다. 같은 man
  #    페이지가 enable 의 대상을 "user and user-login domains" 로 적으므로 user/ 를
  #    1순위로, gui/ 를 보조로 둔다. 방어용이라 둘 다 비치명이다.
  launchctl enable "user/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true

  # 6. 올린다. RunAtLoad 가 여기서 앱을 띄운다.
  local err
  err="$(launchctl bootstrap "$DOMAIN" "$AGENT_PLIST" 2>&1 || true)"

  # 7. 종료 코드가 아니라 실제 상태로 판정한다. 등록이 안 된 채 "완료" 를 찍는 것이
  #    이 기능에서 가능한 최악의 결과다.
  if ! job_loaded; then
    echo "  등록 실패: $DOMAIN/$LABEL" >&2
    if [ -n "$err" ]; then echo "  launchctl: $err" >&2; fi
    echo "  진단:  launchctl print-disabled $DOMAIN | grep $LABEL" >&2
    echo "         tail \"$STDERR_LOG\"" >&2
    exit 1
  fi

  STARTED_BY_LAUNCHD=1
  echo "  등록됨: $AGENT_PLIST"
  echo "  잡:     $DOMAIN/$LABEL"
  echo "  로그:   $STDOUT_LOG / $STDERR_LOG"

  # 8. bootstrap 이 성공해도 앱이 안 뜰 수 있다. 시스템 설정 → 일반 → 로그인 항목 →
  #    "백그라운드에서 허용" 을 꺼 두면 BTM 이 막는데, launchctl enable 은 launchd 의
  #    disabled DB 만 건드리므로 그걸 되돌리지 못한다. 확인하지 않으면 스크립트가
  #    거짓 성공을 보고한다.
  sleep 1
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "  주의: 등록은 됐는데 앱이 아직 보이지 않습니다." >&2
    echo "        시스템 설정 → 일반 → 로그인 항목 → 백그라운드에서 허용 에서 이 앱이" >&2
    echo "        꺼져 있으면 launchctl 로는 되돌릴 수 없습니다. 그 토글을 켜세요." >&2
    echo "        로그: $STDERR_LOG" >&2
  fi
}

warn_stale_agent
# 반드시 여기서 센다 — 아무것도 죽이기 전이다. --install 과 register_agent 가 각각
# pkill 로 기존 인스턴스를 정리하므로, 그 뒤에서 세면 언제나 1개로 보여 중복을 영영
# 못 잡는다. (--launch 는 띄운 뒤에 한 번 더 센다. 그쪽은 방금 만든 중복을 본다.)
warn_multiple_instances

# 해제는 산출물과 무관한 동사다. 앱을 치우려는 사람에게 동작하는 Swift 툴체인과
# 빌드 시간을 요구할 이유가 없으므로 빌드보다 앞에서 끝낸다.
if [ "$UNREGISTER" -eq 1 ]; then
  unregister_agent
  exit 0
fi

echo "▸ 빌드 ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product "$APP_NAME"
# usagectl도 함께 빌드한다. README의 빠른 시작이 .build 안의 CLI를 바로 부르기 때문이다.
# (따로 `swift build` 해도 상관없다 — 서명은 키체인 접근에 영향을 주지 않는다.)
swift build -c "$CONFIGURATION" --product usagectl

if [ ! -x "$BINARY" ]; then
  echo "실행 파일을 찾지 못했습니다: $BINARY" >&2
  exit 1
fi

echo "▸ 번들 구성"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# 서명. ad-hoc으로 충분하다.
#
# 한때 여기서 자체 서명 인증서를 쓰고 키체인 partition list까지 갱신했다. 재빌드할 때마다
# Claude 토큰 접근 허용 창이 되돌아오는 것을 막기 위해서였는데, 그 방법은 원리적으로
# 유지될 수 없었다 — Claude Code가 토큰을 갱신할 때마다 `security`로 키체인 항목을
# 덮어쓰고, 그때 partition list가 `apple-tool:` 하나로 리셋되면서 등록해 둔 cdhash가
# 지워진다. 지금은 앱이 SecItem*를 직접 부르지 않고 /usr/bin/security를 거쳐 읽으므로
# (Sources/UsageCore/Credentials.swift 참고) 앱의 서명 신원이 키체인 판정에 아예
# 참여하지 않는다. 어떻게 서명하든 창은 뜨지 않는다.
echo "▸ ad-hoc 서명"
codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1 \
  || echo "  (서명 실패 — 처음 실행 시 우클릭 → 열기 로 허용해야 할 수 있습니다)"

echo "  requirement: $(codesign -d -r- "$BUNDLE" 2>&1 | sed -n 's/^# *designated => //p;s/^designated => //p')"

echo "▸ 완료: $BUNDLE"

if [ "$INSTALL" -eq 1 ]; then
  echo "▸ $APP_DEST 로 설치"

  # 복사를 "먼저" 한다. 서비스를 내린 뒤에 복사하면, 쓰기 권한이 없거나 디스크가
  # 찼거나 중간에 끊겼을 때 cp 가 set -e 로 스크립트를 죽이면서 위젯이 내려간 채로
  # 남는다 — 재기동 코드는 저 아래에 있어서 도달하지 못한다. 스테이징이 먼저면 그런
  # 실패가 launchd 를 건드리기 전에 드러나고, 실패해도 돌던 앱은 그대로다.
  TMP_STAGE="$(dirname "$APP_DEST")/.$APP_NAME.app.new.$$"
  rm -rf "$TMP_STAGE"
  cp -R "$BUNDLE" "$TMP_STAGE"

  # 그 다음에 내린다. 등록돼 있으면 번들을 갈아 끼우기 전에 반드시 launchd 를 통해야
  # 한다 — --register 를 안 준 실행에서도 그렇다. launchd 는 경로가 아니라 PID 를
  # 추적하므로, 실행 중에 번들을 지워도 옛 프로세스는 지워진 inode 로 멀쩡히 계속 돌고
  # launchd 는 그걸 정상 동작 중으로 본다 — 사용자가 보는 것은 "설치했는데 예전 버전이
  # 그대로 돈다" 다. 그렇다고 pkill 로 죽이면 SIGTERM 사망은 종료 코드 0 이 아니라
  # KeepAlive 가 방금 지운 옛 바이너리를 되살린다. 두 실패가 서로를 가린다. bootout 은
  # 둘을 한 번에 푼다.
  WAS_LOADED=0
  if job_loaded; then
    WAS_LOADED=1
    job_stop || { echo "  실행 중인 서비스를 내리지 못했습니다: $DOMAIN/$LABEL" >&2; exit 1; }
    echo "  기존 서비스 내림"
  fi
  pkill -x "$APP_NAME" 2>/dev/null || true

  # 여기서부터는 같은 디렉터리 안의 rm + rename 이라 순식간이다. 앱이 없는 창이 그만큼
  # 짧다.
  rm -rf "$APP_DEST"
  mv "$TMP_STAGE" "$APP_DEST"
  TMP_STAGE=""

  BUNDLE="$APP_DEST"
  echo "  설치됨: $BUNDLE"

  # --register 를 안 줬어도 원래 등록돼 있었다면 원상 복구한다. --register 를 준
  # 실행에서는 곧 register_agent 가 새 plist 로 다시 올리므로 여기서는 건드리지 않는다.
  if [ "$WAS_LOADED" -eq 1 ] && [ "$REGISTER" -eq 0 ]; then
    launchctl bootstrap "$DOMAIN" "$AGENT_PLIST" >/dev/null 2>&1 || true
    if job_loaded; then
      STARTED_BY_LAUNCHD=1
      echo "  LaunchAgent 다시 올림 (새 바이너리로 기동)"
    else
      echo "  경고: LaunchAgent 를 다시 올리지 못했습니다. $SELF --register 로 복구하세요." >&2
    fi
  fi
fi

if [ "$REGISTER" -eq 1 ]; then
  register_agent
fi

if [ "$LAUNCH" -eq 1 ]; then
  echo "▸ 실행"
  if [ "$STARTED_BY_LAUNCHD" -eq 1 ]; then
    echo "  launchd 가 이미 띄웠습니다 (RunAtLoad)."
  elif job_loaded; then
    # 플래그가 아니라 실제 등록 상태로 분기한다. 손으로 등록해 둔 사람이 나중에
    # --launch 만 돌리는 경우까지 걸린다.
    #
    # 여기서 pkill + open 을 쓰면 안 된다. pkill 의 SIGTERM 은 종료 코드 0 이 아니라
    # KeepAlive 가 발동하는데, 이 잡의 minimum runtime 이 10초라 재기동이 늦다. 그
    # 사이 open 이 먼저 인스턴스를 만들고, 뒤늦은 launchd 는 LaunchServices 를 조회
    # 하지 않고 실행 파일을 직접 exec 하므로 "이미 떠 있으면 활성화만" 규칙을 타지
    # 않는다 — 메뉴바 아이콘이 둘이 된다. 재시작은 launchd 에게 맡긴다.
    if [ "$INSTALL" -eq 0 ]; then
      echo "  주의: launchd 는 $APP_DEST 를 띄웁니다 — 방금 만든 $BUNDLE 이 아닙니다." >&2
    fi
    # 성공 메시지를 kickstart 결과와 묶는다. 떼어 놓으면 실패 경고 바로 다음 줄에
    # "재시작했다" 가 찍혀 서로 모순되는 출력이 나온다 — 이 스크립트는 다른 곳에서
    # 종료 코드가 아니라 실제 상태로 판정하기로 해 놓고 여기서만 어겼었다.
    if launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      echo "  launchd 로 재시작: $DOMAIN/$LABEL"
    else
      echo "  재시작 실패 — launchctl kickstart -k $DOMAIN/$LABEL 를 직접 실행해 보세요" >&2
    fi
  else
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.5
    open "$BUNDLE"
  fi

  sleep 1
  warn_multiple_instances
  echo "  메뉴바를 확인하세요."
fi

# 히어독은 분기할 수 없으니 변수로 미리 만든다. <<INFO 는 인용되지 않은 구분자라
# 확장이 일어나지만 확장은 1패스다 — 변수 '값' 안의 문자는 다시 스캔되지 않는다.
# job_loaded 만으로 kickstart 를 안내하면 안 된다. --install 을 안 준 실행에서는 방금
# 빌드한 것이 build/ 에 있고 launchd 가 띄우는 것은 /Applications 의 옛 번들이라,
# kickstart 는 바뀐 것이 하나도 없는 앱을 재시작할 뿐이다 — 안내대로 했는데 변경이
# 반영되지 않는, 원인을 짐작하기 어려운 실패다.
if job_loaded && [ "$INSTALL" -eq 1 ]; then
  RUN_LINE="재시작     launchctl kickstart -k $DOMAIN/$LABEL"
  AUTOSTART_LINE="자동 실행   등록됨 (해제: $SELF --unregister)"
elif job_loaded; then
  RUN_LINE="반영       $SELF --install   (방금 빌드한 것은 아직 등록된 앱이 아닙니다)"
  AUTOSTART_LINE="자동 실행   등록됨 (해제: $SELF --unregister)"
elif [ -f "$AGENT_PLIST" ]; then
  RUN_LINE="실행       open \"$BUNDLE\""
  AUTOSTART_LINE="자동 실행   plist 는 있는데 올라와 있지 않습니다 — $SELF --register"
else
  RUN_LINE="실행       open \"$BUNDLE\""
  AUTOSTART_LINE="자동 실행   $SELF --register"
fi

cat <<INFO

다음 단계
  $RUN_LINE
  $AUTOSTART_LINE
  숫자 검증   .build/$CONFIGURATION/usagectl status
INFO

if job_loaded; then
  cat <<INFO
  상태 확인   launchctl print $DOMAIN/$LABEL | grep -E 'state =|pid =|last exit'
  로그       tail "$STDERR_LOG"
INFO
fi
