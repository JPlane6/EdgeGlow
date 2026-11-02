#!/usr/bin/env bash
# Builds build/EdgeGlow.app, code-signs it, and launches it.
#   ./build.sh             build + launch
#   ./build.sh --dmg       also package build/EdgeGlow.dmg
#   ./build.sh --no-launch build only (CI)
#
# Signing: ad-hoc by default. Ad-hoc signatures change on every build, so macOS forgets the Screen &
# System Audio Recording grant after each rebuild. To keep it, sign with a stable identity, e.g. a
# self-signed "Code Signing" certificate created in Keychain Access:
#   SIGN_IDENTITY="EdgeGlow Dev" ./build.sh
set -euo pipefail

cd "$(dirname "$0")"

MAKE_DMG=false
LAUNCH=true
for arg in "$@"; do
    case "$arg" in
        --dmg) MAKE_DMG=true ;;
        --no-launch) LAUNCH=false ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

APP="build/EdgeGlow.app"

echo "==> Cleaning $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling"
swiftc Sources/EdgeGlow/*.swift \
    -O \
    -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -o "$APP/Contents/MacOS/EdgeGlow"

echo "==> Copying Info.plist"
cp Config/Info.plist "$APP/Contents/Info.plist"
# Without these usage strings macOS refuses the Automation and Screen & System Audio Recording prompts.
for key in NSAppleEventsUsageDescription NSScreenCaptureUsageDescription NSAudioCaptureUsageDescription; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 \
        || { echo "error: Config/Info.plist is missing $key" >&2; exit 1; }
done

echo "==> Code-signing (${SIGN_IDENTITY:-ad-hoc})"
codesign --force --deep --sign "${SIGN_IDENTITY:--}" --entitlements Config/entitlements.plist "$APP"

if $MAKE_DMG; then
    echo "==> Packaging build/EdgeGlow.dmg"
    STAGING="build/dmg-staging"
    rm -rf "$STAGING" build/EdgeGlow.dmg
    mkdir -p "$STAGING"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname EdgeGlow -srcfolder "$STAGING" -ov -format UDZO build/EdgeGlow.dmg
    rm -rf "$STAGING"
fi

if $LAUNCH; then
    echo "==> Launching"
    killall EdgeGlow 2>/dev/null || true
    open "$APP"
fi

echo "==> Done"
