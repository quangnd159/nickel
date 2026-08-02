# Nickel

A native macOS menu-bar-triggered note capture app: double-Shift grabs the current text selection into a quick-entry panel.

## Commands

| Purpose | Command | Notes |
|---|---|---|
| Build | `swift build` | SwiftPM, macOS 14+, zero external dependencies — keep it that way |
| Test | `swift test` | XCTest, `Tests/NickelTests/`, 26 tests, runs in seconds |
| App bundle | `./scripts/build-app.sh` | Release build + `.app` in `build/`. **Do not run unless asked** — the user rebuilds/installs on request |
| Install | `./scripts/build-app.sh --install` | Copies to `/Applications/Nickel.app`. Same rule: only on request |

## Environment variables

- `NICKEL_STORE_PATH`: points the store at an alternate JSON file instead of the real Application Support one (`Sources/Nickel/Store/NoteStore.swift:36-40`).
- `NICKEL_DEBUG=1`: enables `NSLog`-based debug logging (`Sources/Nickel/Support/DebugLog.swift:5`).

## Architecture

- `Sources/Nickel/Store/`: model + JSON persistence.
- `Sources/Nickel/Panel/`: SwiftUI panel UI + AppKit interop.
- `Sources/Nickel/Support/`: utilities (settings, updates, markdown conversion, permissions).
- `AppDelegate.swift` + `HotkeyMonitor.swift` + `CaptureEngine.swift`: app lifecycle and global capture.

## Deliberate decisions — do not "fix"

- Note lists use plain `VStack`, never `LazyVStack`. Rows migrate between the ungrouped and per-section `ForEach` loops when a note moves into a section, and `LazyVStack`'s per-identity cell cache would keep serving the pre-move `Note` snapshot (stale done-checkbox). See the comment at `Sources/Nickel/Panel/PanelView.swift:312-318`.
- Nickel is a standard Dock-icon app, not `LSUIElement`.
- Storage is local-only by design: a local JSON file, no accounts, no sync, no cloud.

## Signing & Accessibility caveat

`scripts/build-app.sh` signs with a self-signed "Nickel Dev Signing" identity in the login keychain when present and trusted, else falls back to ad-hoc (`codesign --sign -`). With the dev signing cert installed, the signature is stable across rebuilds and the Accessibility grant survives. Under the ad-hoc fallback, every rebuild has no stable identity, so macOS/TCC treats the app as new and the Accessibility grant is lost — double-Shift stops being detected until it's re-granted in System Settings → Privacy & Security → Accessibility. See README "Signing note".

## Testing notes

- `swift test` covers `NoteStore` and model/logic code — headlessly verifiable.
- The AX/hotkey capture layer (`HotkeyMonitor.swift`, `CaptureEngine.swift`) cannot be verified headlessly; it requires a real Accessibility grant and manual/UI testing.

## Bar for all work

Standard native macOS behavior per current Apple HIG/docs. Prefer subtractive fixes over added machinery.
