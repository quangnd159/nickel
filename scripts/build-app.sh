#!/usr/bin/env bash
set -euo pipefail

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install)
      INSTALL=1
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

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

if [ "$INSTALL" -eq 1 ]; then
  INSTALLED_APP="/Applications/Nickel.app"
  rm -rf "$INSTALLED_APP"
  ditto "$APP_BUNDLE" "$INSTALLED_APP"
  echo "Installed to: $INSTALLED_APP"
fi
