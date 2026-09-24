#!/bin/zsh
# Builds a downloadable YoClicky DMG for a GitHub release.
#
#   scripts/build-dmg.sh              # version from the app's Info.plist
#   scripts/build-dmg.sh 1.1.0        # explicit version
#
# Signing, best available first:
#   1. "Developer ID Application" certificate (Apple Developer Program, $99/yr):
#      signed with the hardened runtime, and notarized + stapled if
#      NOTARY_PROFILE names a `xcrun notarytool store-credentials` profile.
#      Users can open it with a normal double-click.
#   2. Otherwise ad-hoc signed. It works, but macOS warns on first open; the
#      README explains "Open Anyway". (A personal "Apple Development"
#      certificate is not used for releases: it doesn't help Gatekeeper on
#      other Macs and would embed your Apple ID email in the app.)
#
# Output: dist/YoClicky-<version>.dmg and its SHA-256.
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

APP_NAME="YoClicky"
BUILD_DIR="build/release-dmg"
DIST_DIR="dist"
STAGING_DIR="$BUILD_DIR/dmg-staging"

echo "==> Building universal (Apple Silicon + Intel) release"
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy \
  -configuration Release -derivedDataPath "$BUILD_DIR/derived" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES \
  OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $PWD=." \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

BUILT_APP="$BUILD_DIR/derived/Build/Products/Release/$APP_NAME.app"

# Coverage instrumentation (on by default in the scheme xcodebuild generates)
# embeds absolute source paths, which contain the builder's macOS username.
# Refuse to ship a binary that still has any path from this Mac in it.
if LC_ALL=C grep -a -q "$HOME/" "$BUILT_APP/Contents/MacOS/$APP_NAME"; then
  echo "error: the app binary contains paths from $HOME; not packaging it" >&2
  exit 1
fi
VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT_APP/Contents/Info.plist")}"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$DIST_DIR"
cp -R "$BUILT_APP" "$STAGING_DIR/"
STAGED_APP="$STAGING_DIR/$APP_NAME.app"

DEVELOPER_ID_IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)"
if [[ -n "$DEVELOPER_ID_IDENTITY" ]]; then
  echo "==> Signing with $DEVELOPER_ID_IDENTITY (hardened runtime)"
  codesign --force --deep --timestamp --options runtime \
    --entitlements leanring-buddy/leanring-buddy.entitlements \
    --sign "$DEVELOPER_ID_IDENTITY" "$STAGED_APP"
else
  echo "==> No Developer ID certificate found: ad-hoc signing (users will see a Gatekeeper warning)"
  codesign --force --deep --entitlements leanring-buddy/leanring-buddy.entitlements --sign - "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"

ln -s /Applications "$STAGING_DIR/Applications"

DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG_PATH"
echo "==> Creating $DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null

if [[ -n "$DEVELOPER_ID_IDENTITY" && -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing (this can take a few minutes)"
  codesign --force --timestamp --sign "$DEVELOPER_ID_IDENTITY" "$DMG_PATH"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
fi

echo "==> Done"
echo "    $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo "    SHA-256: $(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"
