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

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIGURATION="debug" ;;
    --install) INSTALL=1 ;;
    --launch) LAUNCH=1 ;;
    -h|--help)
      cat <<'USAGE'
사용법: scripts/build-app.sh [옵션]

  --debug     디버그 빌드로 번들 생성 (기본: release)
  --install   생성한 앱을 /Applications 로 복사
  --launch    생성한 앱 실행 (이미 떠 있으면 먼저 종료)
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

echo "▸ 빌드 ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product "$APP_NAME"
# usagectl도 함께 빌드한다. SwiftPM은 링크할 때마다 ad-hoc 서명을 새로 붙이므로,
# CLI를 따로 `swift build` 하면 아래 재서명이 무효가 되고 키체인이 다시 묻는다.
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

# 서명. 이름이 붙은 인증서가 있으면 그걸 쓴다.
#
# ad-hoc 서명(--sign -)은 designated requirement가 바이너리 해시라서, 재빌드할 때마다
# 키체인이 이 앱을 "다른 앱"으로 보고 "항상 허용" 기록을 버린다. 그러면 Claude 사용량을
# 읽을 때마다 접근 허용 창이 다시 뜬다. 인증서로 서명하면 requirement가 인증서 기준이
# 되어 재빌드해도 허용이 유지된다. 인증서는 scripts/create-signing-cert.sh 로 만든다.
IDENTITY="${SIGN_IDENTITY:-AIUsageBar Self Signed}"

SIGNED_WITH_CERT=0
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1 \
   && codesign --force --sign "$IDENTITY" --timestamp=none \
        --identifier com.daegun.aiusagebar "$BUNDLE" >/dev/null 2>&1; then
  echo "▸ 서명: $IDENTITY"
  SIGNED_WITH_CERT=1
else
  echo "▸ ad-hoc 서명 (인증서 '$IDENTITY' 없음)"
  codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1 \
    || echo "  (서명 실패 — 처음 실행 시 우클릭 → 열기 로 허용해야 할 수 있습니다)"
  echo "  ! 재빌드할 때마다 키체인 접근 창이 다시 뜹니다."
  echo "    없애려면: scripts/create-signing-cert.sh"
fi

echo "  requirement: $(codesign -d -r- "$BUNDLE" 2>&1 | sed -n 's/^# *designated => //p;s/^designated => //p')"

# usagectl도 같은 키체인 항목을 읽는다. SwiftPM은 빌드할 때마다 ad-hoc으로 서명하므로,
# 그대로 두면 CLI를 다시 빌드할 때마다 접근 허용 창이 따로 뜬다.
CLI="$ROOT/.build/$CONFIGURATION/usagectl"
if [ "$SIGNED_WITH_CERT" -eq 1 ] && [ -x "$CLI" ]; then
  if codesign --force --sign "$IDENTITY" --timestamp=none \
       --identifier com.daegun.usagectl "$CLI" >/dev/null 2>&1; then
    echo "▸ usagectl 서명 완료"
  fi
fi

echo "▸ 완료: $BUNDLE"

if [ "$INSTALL" -eq 1 ]; then
  echo "▸ /Applications 로 설치"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$BUNDLE" "/Applications/$APP_NAME.app"
  BUNDLE="/Applications/$APP_NAME.app"
  echo "  설치됨: $BUNDLE"
fi

if [ "$LAUNCH" -eq 1 ]; then
  echo "▸ 실행"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  open "$BUNDLE"
  echo "  메뉴바를 확인하세요."
fi

cat <<INFO

다음 단계
  실행       open "$BUNDLE"
  자동 실행   시스템 설정 → 일반 → 로그인 항목 에서 이 앱을 추가
  숫자 검증   .build/$CONFIGURATION/usagectl status
INFO
