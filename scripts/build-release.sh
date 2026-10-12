#!/bin/bash
# prtvpn 배포용 빌드 스크립트.
#   scripts/build-release.sh           # Release 로 빌드해 build/prtvpn.app 과 build/prtvpn-<버전>.zip 을 만듦
#   CONF=Debug scripts/build-release.sh
#   DERIVED=/path/to/DerivedData scripts/build-release.sh
#
# Apple 개발자 계정 없이 동작함: 앱은 서명 없이 빌드한 뒤, 이 컴퓨터에서 만든 자체 서명 인증서로 서명함.
# 터널 데몬은 설치될 때 이 인증서의 지문을 기억해 두고, 같은 인증서로 서명된 앱의 요청만 받음.
# 따라서 build/signing 안의 개인 키가 유출되면 누구나 데몬이 신뢰하는 앱을 만들 수 있음. 절대 공유하거나 커밋하지 말 것.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${CONF:-Release}"
# 패키지를 다시 받지 않도록 기존 DerivedData 를 쓰려면 DERIVED 로 지정함
DERIVED="${DERIVED:-$ROOT/build/DerivedData}"
SIGNING="$ROOT/build/signing"
KEYCHAIN="$SIGNING/prtvpn-signing.keychain-db"
APP="$ROOT/build/prtvpn.app"
IDENTITY_NAME="prtvpn local signing"

cd "$ROOT"
mkdir -p "$ROOT/build"

# MARK: 서명 인증서 (없을 때만 새로 만듦. 한 번 만든 인증서를 계속 써야 앱을 업데이트해도 데몬이 받아 줌)
if [ ! -f "$KEYCHAIN" ]; then
    echo "==> 자체 서명 인증서 생성"
    mkdir -p "$SIGNING"
    chmod 700 "$SIGNING"
    umask 077
    /usr/bin/openssl rand -hex 24 > "$SIGNING/pw.txt"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$SIGNING/key.pem" -out "$SIGNING/cert.pem" \
        -subj "/CN=$IDENTITY_NAME" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$SIGNING/key.pem" -in "$SIGNING/cert.pem" \
        -name "$IDENTITY_NAME" -out "$SIGNING/id.p12" -passout "file:$SIGNING/pw.txt"
    security create-keychain -p "$(cat "$SIGNING/pw.txt")" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"
    security import "$SIGNING/id.p12" -k "$KEYCHAIN" -P "$(cat "$SIGNING/pw.txt")" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$SIGNING/pw.txt")" "$KEYCHAIN" >/dev/null
    umask 022
fi
# 개인 키와 암호는 이 사용자만 읽을 수 있게 함
chmod 700 "$SIGNING"
chmod 600 "$SIGNING"/*
security unlock-keychain -p "$(cat "$SIGNING/pw.txt")" "$KEYCHAIN"
IDENTITY="$(security find-identity "$KEYCHAIN" | grep -m1 -o -E '[0-9A-F]{40}')"
[ -n "$IDENTITY" ] || { echo "서명 인증서를 찾을 수 없습니다: $KEYCHAIN" >&2; exit 1; }

# MARK: 앱 빌드 (서명 없이)
echo "==> 앱 빌드 ($CONF)"
LOG="$ROOT/build/xcodebuild.log"
# Homebrew git 이 패키지 해석을 깨뜨리는 환경이 있어 Apple git 을 먼저 찾게 함
if ! PATH="/usr/bin:$PATH" xcodebuild -workspace ProtonVPN.xcworkspace -scheme ProtonVPN-macOS \
    -configuration "$CONF" -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build > "$LOG" 2>&1; then
    grep -E '^/.*: error: |^error: |xcodebuild: error|Undefined symbols' "$LOG" | sort -u | head -40 >&2
    echo "빌드 실패. 전체 로그: $LOG" >&2
    exit 1
fi

# MARK: 번들 조립
echo "==> 번들 조립"
if [ -d "$APP" ]; then
    if command -v trash >/dev/null; then trash "$APP"; else mv "$APP" "$ROOT/build/prtvpn.app.old-$(date +%s)"; fi
fi
cp -R "$DERIVED/Build/Products/$CONF/prtvpn.app" "$APP"

echo "==> 터널 데몬 빌드"
(cd apps/macos/prtvpn-daemon && GOFLAGS=-mod=mod go build -trimpath -ldflags=-w -o "$APP/Contents/Resources/prtvpn-daemon" .)

# MARK: 서명
echo "==> 서명"
codesign --force --keychain "$KEYCHAIN" -s "$IDENTITY" -i app.prtvpn.daemon "$APP/Contents/Resources/prtvpn-daemon" 2>/dev/null
codesign --force --deep --keychain "$KEYCHAIN" -s "$IDENTITY" "$APP" 2>/dev/null
# 데몬은 하드닝된 런타임으로 서명된 앱만 받아 줌. 팀 ID 가 없는 인증서라 라이브러리 검증은 꺼야 프레임워크가 로드됨.
codesign --force --keychain "$KEYCHAIN" -s "$IDENTITY" -o runtime \
    --entitlements apps/macos/ProtonVPN/prtvpn-local.entitlements "$APP" 2>/dev/null
codesign --verify --deep --strict "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
    echo "get-task-allow 권한이 들어 있습니다. 배포하면 안 되는 빌드입니다." >&2
    exit 1
fi
codesign -d -r- "$APP" 2>&1 | tail -1

# MARK: 압축
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$ROOT/build/prtvpn-$VERSION.zip"
[ -f "$ZIP" ] && { if command -v trash >/dev/null; then trash "$ZIP"; else mv "$ZIP" "$ZIP.old-$(date +%s)"; fi; }
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> 완료"
echo "앱:  $APP"
echo "zip: $ZIP"
shasum -a 256 "$ZIP"
