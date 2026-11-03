#!/usr/bin/env bash
# Regenerates AppIcon-1024.png, AppIcon.icns and AppIcon.ico (macOS only: needs swiftc + iconutil).
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swiftc -O make_icons.swift -o "$TMP/make_icons"
"$TMP/make_icons" "$PWD"
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
ls -l AppIcon-1024.png AppIcon.icns AppIcon.ico
