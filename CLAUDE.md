# Nickel

A native macOS note capture app, a clipboard that remembers: double-Shift grabs the current text selection (formatting preserved as Markdown) into a quick-entry panel. Primary use case: capturing things to ask or tell an AI agent later without switching context; also used as a general to-do list.

## Commands

| Purpose | Command | Notes |
|---|---|---|
| Build | `swift build` | SwiftPM, macOS 26+, zero external dependencies — keep it that way |
| Test | `swift test` | XCTest, `Tests/NickelTests/`, runs in seconds |
| List geometry | `swift build && NICKEL_UI_PROBE=1 .build/debug/Nickel` | Checks real row heights, hit-testing and row-at-point in an offscreen panel (`Sources/Nickel/Support/UIProbe.swift`). Exits 0/1, prints every row's frame. Run it after any change to row sizing or hit-testing |
| App bundle | `./scripts/build-app.sh` | Release build + `.app` in `build/`. **Do not run unless asked** — the user rebuilds/installs on request |
| Install | `./scripts/build-app.sh --install` | Copies to `/Applications/Nickel.app`. Same rule: only on request |

## Environment variables

- `NICKEL_STORE_PATH`: points the store at an alternate JSON file instead of the real Application Support one (`Sources/Nickel/Store/NoteStore.swift:36-40`).
- `NICKEL_DEBUG=1`: enables `NSLog`-based debug logging (`Sources/Nickel/Support/DebugLog.swift:5`).
- `NICKEL_UI_PROBE=1`: runs the note list's geometry checks instead of the app — no status item, no hotkey monitor, no Accessibility grant needed (`Sources/Nickel/Support/UIProbe.swift`).

## Architecture

- `Sources/Nickel/Store/`: model + JSON persistence.
- `Sources/Nickel/Panel/`: SwiftUI panel UI + AppKit interop.
- `Sources/Nickel/Support/`: utilities (settings, updates, markdown conversion, permissions).
- `AppDelegate.swift` + `HotkeyMonitor.swift` + `CaptureEngine.swift`: app lifecycle and global capture.

## Deliberate decisions — do not "fix"

- The note list and the Logbook are a view-based `NSTableView` (`Sources/Nickel/Panel/NoteListTable.swift`), not a SwiftUI `ScrollView`. The table owns click, ⇧-click, ⌘-click, arrows, ⌘A, right-click's `clickedRow` and scrolling; row *content* is still SwiftUI, hosted per cell. Two rules keep that working, and neither is safe to "tidy away":
  - A row's hosting view returns `nil` from `hitTest` unless it needs clicks itself (a section header, or the one note being edited). SwiftUI content would otherwise swallow every click and the table would never see one.
  - The selected look is the 2pt outline drawn by the row's own SwiftUI content; `NoteListRowView` suppresses AppKit's default filled highlight. Don't swap in the default.
  - Row content reads its note out of the store by id, so a cell that stays put across a list update can't render a stale `Note`. (This replaced an older rule about never using `LazyVStack`, which existed to dodge exactly that staleness.)
  - Row heights come from `tableView(_:heightOfRow:)` over a cache, **not** `usesAutomaticRowHeights` — that was tried and leaves every row at the height it first measured. And each cell pins its content's width in SwiftUI (`.frame(width:)`) before hosting it: `NSHostingView` reports the content's *ideal* size, and a `Text`'s ideal size is its unwrapped single line, so an unpinned multi-line note measures one line tall. Both are verified by `NICKEL_UI_PROBE=1` (see Commands); re-run it after touching row sizing.
  - Nothing measures or re-hosts content inside a layout pass. `heightOfRow` is a pure cache lookup and every measurement happens on a deferred turn; measuring inline re-enters Auto Layout and crashes.
  - A row growing and the list scrolling to reveal it are **one** animation. Both happen inside the height flush's single `NSAnimationContext` group, so don't add a scroll anywhere that reacts to the growth afterwards (the inline editor used to, and it read as two separate motions).
- Drag to reorder (`Sources/Nickel/Panel/NoteListDrop.swift` + the drag section of `NoteListTable.swift`) has its own rules:
  - `validateDrop` and `acceptDrop` both go through `NoteListDrop.resolve`, so what the drop indicator promises and what the store is told can't disagree. Don't let one of them grow its own logic.
  - `acceptDrop` mutates the store and lets the normal diff move the rows. No `moveRow(at:to:)` — that would make the table a second source of truth for note order.
  - No positional drops while a search filter is active: the note above a gap on screen isn't the note above it in the list. Drops **onto a section header** stay allowed, since "into this section, at its end" is unambiguous either way. Reminders disables filtered reordering for the same reason.
  - Dropping onto a section header is the only way to reach a section with no notes. Don't remove it as redundant.
  - The Logbook is neither drag source nor drop target, and drags from other apps into the list are not accepted — the composer's own drop area (`ComposerDropView.swift`) handles those, and it is deliberately AppKit-level.
  - Local drags are `.move`, external drags `.copy`; rows also carry `.string`, so dragging a note into another app pastes its text.
- Nickel is a standard Dock-icon app, not `LSUIElement`.
- Storage is local-only by design: a local JSON file, no accounts, no sync, no cloud.

## Signing & Accessibility caveat

`scripts/build-app.sh` signs with a self-signed "Nickel Dev Signing" identity in the login keychain when present and trusted, else falls back to ad-hoc (`codesign --sign -`). With the dev signing cert installed, the signature is stable across rebuilds and the Accessibility grant survives. Under the ad-hoc fallback, every rebuild has no stable identity, so macOS/TCC treats the app as new and the Accessibility grant is lost — double-Shift stops being detected until it's re-granted in System Settings → Privacy & Security → Accessibility. See README "Signing note".

## Testing notes

- `swift test` covers `NoteStore` and model/logic code — headlessly verifiable.
- The AX/hotkey capture layer (`HotkeyMonitor.swift`, `CaptureEngine.swift`) cannot be verified headlessly; it requires a real Accessibility grant and manual/UI testing. Exception: `CaptureEngine.pasteboardResultMatchesAXText` is a pure helper with unit tests.
- The note list's real geometry is out of `swift test`'s reach but not out of reach: `NICKEL_UI_PROBE=1` drives a real panel offscreen and asserts on actual row frames. Reach for it before guessing at a layout bug.

## Bar for all work

Standard native macOS behavior per current Apple HIG/docs. Prefer subtractive fixes over added machinery.
