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
  - The selected look is a 2pt border on the cell's layer (the layer that also carries the rounded clip), driven by `NoteListRowView`'s `isSelected`/`isEmphasized`; AppKit's default filled highlight is suppressed. Don't swap in the default, and don't move the ring into the SwiftUI content — static content is clipped mid-height-animation, which visibly cuts the ring.
  - Row content reads its note out of the store by id, so a cell that stays put across a list update can't render a stale `Note`. (This replaced an older rule about never using `LazyVStack`, which existed to dodge exactly that staleness.)
  - Row heights come from `tableView(_:heightOfRow:)` over a cache, **not** `usesAutomaticRowHeights` — that was tried and leaves every row at the height it first measured. And each cell pins its content's width in SwiftUI (`.frame(width:)`) before hosting it: `NSHostingView` reports the content's *ideal* size, and a `Text`'s ideal size is its unwrapped single line, so an unpinned multi-line note measures one line tall. Both are verified by `NICKEL_UI_PROBE=1` (see Commands); re-run it after touching row sizing.
  - Nothing measures or re-hosts content inside a layout pass. `heightOfRow` is a pure cache lookup and every measurement happens on a deferred turn; measuring inline re-enters Auto Layout and crashes.
  - A row growing and the list scrolling to reveal it are **one** animation. Both happen inside the height flush's single `NSAnimationContext` group, so don't add a scroll anywhere that reacts to the growth afterwards (the inline editor used to, and it read as two separate motions).
  - Row height animations (expand/collapse, inline edit open/close) work by **clipping static content, never by resizing it**. The cell has no bottom constraint: the hosted content sits at its intrinsic (final) height from the first frame, and the animating cell is a clipping window sliding over it, with the card's corner radius on the cell's layer so the bottom edge stays a closed rounded corner mid-animation. Don't add a bottom constraint "for completeness" (it forces a SwiftUI relayout on every animation tick, and SwiftUI centers over-tall content — the text visibly drifts; the probe's edit-open stationarity check fails on exactly this) and don't wrap the row-affecting state changes in `withAnimation` (a second animation curve nested inside AppKit's reads as bounce). Collapse keeps the outgoing content rendered until the animation completes (`SelectionModel.collapseHold`, released by the flush's completion handler), so the card visibly closes over it.
- Drag to reorder (`Sources/Nickel/Panel/NoteListDrop.swift` + the drag section of `NoteListTable.swift`) has its own rules:
  - `validateDrop` and `acceptDrop` both go through `NoteListDrop.resolve`, so what the drop indicator promises and what the store is told can't disagree. Don't let one of them grow its own logic.
  - `acceptDrop` mutates the store — still the only truth for note order — and then re-seats the affected rows with `moveRow(at:to:)` to the order the store now implies (`applyDropAsMoves`). That's presentation only: the following update diffs to nothing. Don't "simplify" it away and leave the drop to the diff; the diff expresses a reorder as a removal plus an insertion, which is the dropped row flashing out and back in.
  - The drop also animates the floating drag image onto its landed row (`landDragImages`), which is why `acceptDrop` sets `animatesToDestination` and each item's `draggingFrame` — the documented sequence, and it must happen during the drop itself.
  - **No drops while a search filter is active.** Every drop is positional, and the note above a gap on screen isn't the note above it in the list. Reminders disables filtered reordering for the same reason.
  - **Nothing is an on-row drop target** — not notes, not section headers. Every drop lands in a gap between rows (`draggingDestinationFeedbackStyle = .gap`), and a proposed `.on` is retargeted to `.above`. That's why there's no `drawDraggingDestinationFeedback(in:)` override: with no on-row targets it would have no caller.
  - An **empty section** is reached by the gap directly below its header, which is why `.above` a header resolves to the section of the row *above* it — and when that row is itself a header, to that header's own empty section. Consecutive empty sections each get their own gap. Don't "simplify" that case away.
  - `tableView(_:heightOfRow:)` must stay a pure cache lookup that schedules nothing for out-of-range rows: `.gap` asks about rows that aren't in the model while it opens a drop gap.
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
