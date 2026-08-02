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
