# Plan 028: Give the panel a minimum size and make width invalidation non-destructive

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. On
> any STOP condition, stop and report. When done, update this plan's row in
> `plans/README.md` — unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/Panel/FloatingPanel.swift Sources/Nickel/Panel/NoteListTable.swift Sources/Nickel/Support/UIProbe.swift`
> On any change, compare the excerpts below against live code; mismatch = STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

Two resize defects. (1) The borderless, resizable panel declares no minimum
size, so it can be dragged down to a few points; the broken frame is then
persisted and restored on every launch, with no in-app recovery. Native
windows always declare a floor. (2) On every width change the list wipes its
entire row-height cache (`rowHeights.removeAll()`), so the table retiles with
the 45pt placeholder for every row for at least one runloop turn — a visible
snap-to-uniform flash and wrong geometry for any in-flight scroll/reveal. The
codebase already has the correct pattern (mark stale, keep the old height
until the new one is known) in the adjacent method.

## Current state

- `Sources/Nickel/Panel/FloatingPanel.swift:37-51` — panel init;
  `styleMask: [.borderless, .resizable]`, size 360×560; no `minSize` is set
  anywhere in the file (`grep -n minSize` → no hits). The saved frame is
  persisted by `saveFrame()` (~line 157) under the `NickelPanelFrame`
  defaults key and restored by `restoreOrPositionFrame()` (~line 126).
- Exemplar: `Sources/Nickel/Panel/NoteEditorWindowManager.swift:86` sets
  `window.minSize = NSSize(width: 320, height: 200)`.
- `Sources/Nickel/Panel/NoteListTable.swift:456-463`:

```swift
/// The panel was resized: every row rewraps its text, so every height is
/// stale.
func invalidateAllRowHeights() {
    guard !rows.isEmpty else { return }
    rowHeights.removeAll()
    pendingAllRowHeights = true
    scheduleHeightFlush()
}
```

- The correct pattern lives directly above, `NoteListTable.swift:422-440`
  (`invalidateChangedRowHeights`): it inserts into `staleHeightRows` and
  keeps old heights, with a doc comment explaining "keeping the old height
  until the new one is known rather than flashing through a placeholder".
- The flush (`flushPendingRowHeights`, ~line 379-408) measures rows in
  `staleHeightRows` (and all rows when `pendingAllRowHeights` is set) via
  the offscreen measuring host, then calls `noteHeightOfRows`.
- Caller: `NoteListTableView.setFrameSize` (`NoteListTable.swift:960-966`)
  invokes `invalidateAllRowHeights()` on every width change.
- `heightOfRow` (~line 352) reads `rowHeights[rows[row]]` and falls back to
  `provisionalRowHeight` (45) on a miss — that fallback is the flash.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | 377 pass |
| Probe | `NICKEL_UI_PROBE=1 .build/debug/Nickel` | all checks passed |

## Scope

**In scope**:
- `Sources/Nickel/Panel/FloatingPanel.swift` (min size + restore clamp)
- `Sources/Nickel/Panel/NoteListTable.swift` (`invalidateAllRowHeights` only)
- `Sources/Nickel/Support/UIProbe.swift` (new checks)

**Out of scope**:
- Coalescing/debouncing resize re-measures (perf plan 036 handles that).
- `saveFrame` timing, `clampToVisibleScreen` logic.
- `maxSize` — not needed; screens bound it naturally.

## Git workflow

- Branch: `advisor/028-resize-robustness` from `main`
  (`git checkout -b advisor/028-resize-robustness main`).

## Steps

### Step 1: Minimum size

In `FloatingPanel`'s convenience init (after the `self.init(...)` call),
set `minSize = NSSize(width: 300, height: 320)` with a comment: enough for
the top bar, one note row, and the composer. In `restoreOrPositionFrame()`,
clamp the restored frame's size up to `minSize` before `setFrame` so an
already-broken saved frame recovers on next launch.

**Verify**: `swift build` → exit 0. Then
`defaults write com.nickel.Nickel NickelPanelFrame "{{100,100},{50,40}}"`
— SKIP this manual defaults step (the bundle id may differ); instead verify
by code reading and note in your report that restore-clamping is covered by
the code path, and delete nothing from defaults.

### Step 2: Stale-not-wipe width invalidation

Replace `rowHeights.removeAll()` in `invalidateAllRowHeights` with
`staleHeightRows.formUnion(rows)`, keep `pendingAllRowHeights = true` only if
the flush requires it to force re-measure of ALL rows (read
`flushPendingRowHeights` first: if `staleHeightRows.formUnion(rows)` already
causes every row to re-measure, drop `pendingAllRowHeights = true` here and
leave that flag for any other callers; if it has no other callers, remove
the flag entirely — subtractive). Update the doc comment: old heights stay
readable until the flush overwrites them, so a mid-resize retile never sees
the placeholder.

**Verify**: `swift build` → exit 0; `swift test` → 377 pass.

### Step 3: Probe checks

Add to `UIProbe.swift` a `checkWidthInvalidationKeepsHeights(table:)`:
resize the panel (change its frame width by, say, −40), then IMMEDIATELY —
before spinning the runloop — ask `heightOfRow` for a known multi-line row
and `check` that it still returns the pre-resize cached height, not 45.
Then spin the runloop (the pattern used by existing checks) and `check` the
height settles to a value matching the cell's layout at the new width
(reuse the comparison logic from `checkCachedHeightsMatchCells`,
`UIProbe.swift:582`).

**Verify**: `NICKEL_UI_PROBE=1 .build/debug/Nickel` → all checks passed.

## Test plan

Probe checks above are the test (geometry is out of XCTest's reach). The
377 XCTests must stay green.

## Done criteria

- [ ] `swift build` exit 0, no warnings
- [ ] `swift test` 377 pass
- [ ] Probe passes incl. new width-invalidation check
- [ ] `grep -n "removeAll" Sources/Nickel/Panel/NoteListTable.swift` shows no
      height-cache wipe in `invalidateAllRowHeights`
- [ ] `grep -n "minSize" Sources/Nickel/Panel/FloatingPanel.swift` → hit
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails.
- `flushPendingRowHeights` turns out NOT to re-measure rows from
  `staleHeightRows` at the current width (i.e. stale entries measure at an
  old width) — report rather than reworking the flush.
- The probe's post-resize settle check fails twice.

## Maintenance notes

- Plan 036 (perf) will change how OFTEN resize re-measures; it depends on
  this plan's stale-not-wipe semantics. Land this first.
- Reviewer: check `pendingAllRowHeights` wasn't left half-removed.
