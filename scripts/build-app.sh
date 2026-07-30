#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift build -c release

APP_BUNDLE="build/Nickel.app"
rm -rf "$APP_BUNDLE"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/Nickel" "$APP_BUNDLE/Contents/MacOS/Nickel"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

IDENTITY="-"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "Nickel Dev Signing"; then
  IDENTITY="Nickel Dev Signing"
fi

if ! codesign --force --sign "$IDENTITY" "$APP_BUNDLE"; then
  echo "codesign with \"$IDENTITY\" failed; falling back to ad-hoc signing" >&2
  IDENTITY="-"
  codesign --force --sign "$IDENTITY" "$APP_BUNDLE"
fi
echo "Signed with identity: $IDENTITY"

echo "$ROOT_DIR/$APP_BUNDLE"
