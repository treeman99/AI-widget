#!/bin/bash
# AIUsageBar 전용 자체 서명(self-signed) 코드서명 인증서를 로그인 키체인에 만든다.
#
# 왜 필요한가
#   ad-hoc 서명(codesign --sign -)은 designated requirement가 바이너리 해시 그 자체다.
#
#     designated => cdhash H"285d8d28..."
#
#   키체인의 "항상 허용"은 이 requirement를 신뢰 목록에 저장한다. 그래서 코드를 한 줄만
#   고쳐 다시 빌드해도 해시가 바뀌고, 키체인은 완전히 다른 앱으로 보아 허용 기록을
#   버린다 — 매번 "Claude Code-credentials를 사용하려고 합니다" 창이 다시 뜨는 이유다.
#
#   이름이 붙은 인증서로 서명하면 requirement가 인증서 기준으로 바뀐다.
#
#     designated => identifier "com.daegun.aiusagebar" and certificate leaf = H"56fcfc13..."
#
#   바이너리가 바뀌어도 인증서는 그대로이므로 "항상 허용"이 계속 유효하다.
#   (Developer ID로 서명된 앱들이 업데이트 후에도 다시 묻지 않는 것과 같은 원리다.)
#
# 대가
#   위 requirement는 identifier와 leaf 해시로만 이뤄지는데, 둘 다 **서명하는 쪽이 정하는
#   값**이다. 그래서 개인키를 쓸 수 있는 프로세스는 아무 바이너리에나 앱과 똑같은
#   requirement를 붙일 수 있고, 그 위조본은 사용자가 앱에 눌러 준 키체인 "항상 허용"을
#   그대로 물려받아 Claude 토큰을 읽는다. ad-hoc 서명에는 없던 위험이다.
#
#   그래서 이 스크립트는 마지막에 실제로 위조를 시도해 보고, 뚫리면 GUI 설정을 안내한다.
set -euo pipefail

CN="${SIGN_IDENTITY:-AIUsageBar Self Signed}"
BUNDLE_ID="com.daegun.aiusagebar"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DAYS=3650

if [ ! -f "$KEYCHAIN" ]; then
  # 이름이 다른 환경(예: 마이그레이션된 계정)에서는 기본 키체인을 쓴다.
  KEYCHAIN="$(security default-keychain | tr -d ' "')"
fi

# 개인키가 승인 없이 쓰이는지 실제로 시험한다.
#
# `security import`에 -T 를 주지 않아도 macOS는 개인키를 무프롬프트로 내주는 경우가 많고,
# `security` CLI에는 이미 들어간 키의 ACL을 조일 수단이 없다(set-key-partition-list는
# partition만 건드리며, codesign은 Apple 서명이라 apple: partition을 통과한다).
# 그러니 짐작하지 말고 시험한다.
#
# 반환: 0 = 보호됨(서명하려면 승인 필요), 1 = 무프롬프트로 위조 가능
check_key_protection() {
  local dir probe
  dir="$(mktemp -d)"
  probe="$dir/forge-probe"
  cp /bin/echo "$probe"
  if codesign --force --sign "$CN" --timestamp=none \
       --identifier "$BUNDLE_ID" "$probe" >/dev/null 2>&1; then
    rm -rf "$dir"
    return 1
  fi
  rm -rf "$dir"
  return 0
}

report_protection() {
  echo
  echo "▸ 개인키 보호 상태 점검"
  if check_key_protection; then
    echo "  보호되고 있습니다 — 서명하려면 승인 창을 거쳐야 합니다."
    return 0
  fi

  cat >&2 <<WARN
  ⚠️  개인키가 승인 없이 사용됩니다.

     지금 상태에서는 이 맥에서 실행되는 어떤 코드든 아래 한 줄로 앱의 서명을 위조해,
     앱에 눌러 준 키체인 "항상 허용"을 물려받아 Claude 토큰을 읽을 수 있습니다.

       codesign -f -s "$CN" -i $BUNDLE_ID <아무_파일>

     막으려면 키체인 접근.app 에서 한 번 설정해야 합니다 (CLI로는 불가능합니다):

       1. 키체인 접근.app 실행 → 왼쪽에서 "로그인" 키체인 선택
       2. 위쪽 "나의 인증서" 탭 → "$CN" 을 펼침
       3. 그 아래 개인 키를 더블클릭 → "접근 제어" 탭
       4. "이 항목에 접근하려면 확인" 을 체크
          (아래 목록에 codesign 이 있으면 선택해서 "−" 로 제거)
       5. "변경사항 저장" → 키체인 암호 입력

     설정한 뒤 이 스크립트를 다시 돌리면 보호 여부를 다시 확인해 줍니다.
     이후 빌드할 때마다 승인 창이 뜹니다 — "허용"을 누르세요.
     "항상 허용"을 누르면 이 설정이 도로 풀립니다.

     설정할 생각이 없다면 인증서 방식을 쓰지 않는 편이 낫습니다. ad-hoc 서명은
     requirement가 바이너리 해시라 위조가 불가능합니다(대신 재빌드마다 키체인 창이 뜹니다):

       security delete-identity -c "$CN"
WARN
  return 1
}

echo "▸ 대상 키체인: $KEYCHAIN"

if security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "▸ 인증서 '$CN' 가 이미 있습니다. 새로 만들지 않습니다."
  echo "  (다시 만들려면: security delete-identity -c \"$CN\" \"$KEYCHAIN\")"
  report_protection || true
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ 키와 인증서 생성 (유효기간 ${DAYS}일)"
cat > "$WORK/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = $CN

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
  -config "$WORK/cert.conf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1

# p12를 macOS가 읽을 수 있게 만든다.
#   - 빈 암호는 security의 MAC 검증이 거부한다. 임시 암호를 쓰고 바로 버린다.
#   - OpenSSL 3의 기본 PBE(AES-256 + SHA-256 MAC)도 거부한다. SHA1/3DES로 낮춘다.
#     키체인에 들어간 뒤에는 키체인 자신의 보호를 받으므로 전송 형식일 뿐이다.
P12_PASS="transfer-$$"
openssl pkcs12 -export \
  -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$CN" -out "$WORK/bundle.p12" -passout "pass:$P12_PASS" >/dev/null 2>&1

echo "▸ 키체인에 등록"
# -T /usr/bin/codesign 을 일부러 주지 않는다. 그것을 주면 codesign 바이너리에 무프롬프트
# 접근을 내주게 되어, 같은 사용자로 실행되는 어떤 코드든 서명을 위조할 수 있다.
# (이것만으로 보호가 보장되지는 않는다 — 그래서 아래에서 실제로 시험한다.)
security import "$WORK/bundle.p12" -k "$KEYCHAIN" -P "$P12_PASS" >/dev/null

echo "▸ 코드서명 용도로 신뢰 설정"
# 범위를 좁게 — 코드서명 정책에만, 사용자 신뢰 도메인에만 건다
# (-d 를 주지 않으므로 관리자 권한을 요구하지 않는다).
if security add-trusted-cert -r trustAsRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null; then
  echo "  완료 (사용자 도메인, 코드서명 정책 한정)"
else
  echo "  건너뜀 — codesign은 대개 이 단계 없이도 동작합니다"
fi

echo
echo "▸ 확인"
if ! security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "  경고: 인증서를 찾지 못했습니다." >&2
  exit 1
fi
echo "  인증서 '$CN' 등록됨"

PROTECTED=0
report_protection && PROTECTED=1

cat <<INFO

다음 단계
  1. scripts/build-app.sh --install --launch
INFO
if [ "$PROTECTED" -eq 1 ]; then
  cat <<'INFO'
     → 서명할 때 "codesign이 키를 사용하려 합니다" 창이 뜹니다. "허용" 을 누르세요.
       ("항상 허용"을 누르면 보호가 풀립니다)
INFO
fi
cat <<'INFO'

  2. 앱이 키체인 접근 창을 띄우면 그때는 "항상 허용" 을 누르세요.
     (이건 앱이 Claude 토큰을 읽기 위한 것으로, 위의 서명 키 창과는 다릅니다)

  3. 이후 앱을 다시 빌드해도 2번은 다시 묻지 않습니다.
INFO
