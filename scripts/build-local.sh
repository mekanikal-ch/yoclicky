#!/bin/zsh
# Builds YoClicky signed with a stable Apple Development identity and installs it
# to /Applications. A stable signature + path keeps macOS privacy permissions
# (mic, screen recording, accessibility) across rebuilds; ad-hoc signing would
# look like a new app on every build and revoke them.
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Any code signing identity in your keychain works (see `security find-identity -v -p codesigning`),
# as long as the same one is used every time.
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}"

# Build unsigned, then sign the finished app ourselves with the stable identity.
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy \
  -configuration Release -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

pkill -x YoClicky 2>/dev/null || true
rm -rf /Applications/YoClicky.app
cp -R build/Build/Products/Release/YoClicky.app /Applications/

codesign --force --deep --sign "$SIGN_IDENTITY" \
  --entitlements leanring-buddy/leanring-buddy.entitlements \
  /Applications/YoClicky.app
codesign -dr - /Applications/YoClicky.app 2>&1 | tail -1
echo "Installed /Applications/YoClicky.app"
