#!/usr/bin/env bash
# Builds EdgeGlow.app (a real macOS bundle), code-signs it, and launches it.
#   ./build.sh             build + launch
#   ./build.sh --dmg       also package EdgeGlow.dmg
#   ./build.sh --no-launch build only (CI)
#
# Signing: ad-hoc by default. Ad-hoc signatures change on every build, so macOS forgets the Screen &
# System Audio Recording grant after each rebuild. To keep it, sign with a stable identity:
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

NAME="EdgeGlow"
APP="$NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "==> Creating bundle structure $APP"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "==> Generating Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>$NAME</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.jplane6.edgeglow</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>$NAME reads what is playing in Spotify, Apple Music and YouTube Music browser tabs to color the glow with the album art and follow the track.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>$NAME requires system audio access to sync lights with the vocal cadence and beat of your music.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSScreenCaptureUsageDescription</key>
	<string>$NAME requires system audio access to sync lights with the vocal cadence and beat of your music.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Installing app icon"
ICON="../assets/AppIcon.icns"
[ -f "$ICON" ] || { echo "error: $ICON missing (run assets/make_icons.sh)" >&2; exit 1; }
cp "$ICON" "$RES_DIR/AppIcon.icns"

echo "==> Compiling into $MACOS_DIR/$NAME"
swiftc Sources/EdgeGlow/*.swift \
    -O \
    -swift-version 5 \
    -target "$(uname -m)-apple-macos14.0" \
    -o "$MACOS_DIR/$NAME"

echo "==> Code-signing (${SIGN_IDENTITY:-ad-hoc})"
codesign --force --deep --sign "${SIGN_IDENTITY:--}" --entitlements Config/entitlements.plist "$APP"

if $MAKE_DMG; then
    echo "==> Packaging $NAME.dmg"
    DMG="$NAME.dmg"
    STAGING="$(mktemp -d)"
    trap 'rm -rf "$STAGING"' EXIT
    rm -f "$DMG"
    cp -R "$APP" "$STAGING/"              # the app bundle
    ln -s /Applications "$STAGING/Applications"   # drag-and-drop install target
    hdiutil create \
        -volname "$NAME" \
        -srcfolder "$STAGING" \
        -fs HFS+ \
        -format UDZO \
        -imagekey zlib-level=9 \
        -ov "$DMG"
    hdiutil verify "$DMG" >/dev/null
    echo "    created $DMG ($(du -h "$DMG" | cut -f1))"
fi

if $LAUNCH; then
    echo "==> Launching"
    killall "$NAME" 2>/dev/null || true
    open "$APP"
fi

echo "==> Done"
