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

# 서명이 없으면 실행할 때마다 Gatekeeper가 막는다. 임시(ad-hoc) 서명으로 충분하다.
echo "▸ ad-hoc 서명"
codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1 \
  || echo "  (서명 실패 — 처음 실행 시 우클릭 → 열기 로 허용해야 할 수 있습니다)"

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
