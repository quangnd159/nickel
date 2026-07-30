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

codesign --force --sign - "$APP_BUNDLE"

echo "$ROOT_DIR/$APP_BUNDLE"
