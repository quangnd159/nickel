# Plan 036: Short-circuit the list update pipeline for keystrokes and coalesce resize re-measures

> **Executor instructions**: Follow this plan step by step, verifying each
> step. On any STOP condition, stop and report. Update this plan's row in
> `plans/README.md` when done — unless a reviewer told you they maintain the
> index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/Panel/NoteListTable.swift Sources/Nickel/Panel/SelectionModel.swift`
> Plans 028 and 035 are EXPECTED to have landed first and to have touched
> these files; re-read the live code for the excerpted regions and proceed
> if the structures described here still exist. STOP only if a described
> mechanism (HeightFlush, refreshExistingCells, invalidateChangedRowHeights)
> is gone or renamed beyond recognition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/028-resize-robustness.md, plans/035-list-perf-cheap.md
- **Category**: perf
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

The table's `updateNSView` fires on ANY published change of the three
environment objects it observes — including `SelectionModel.editingText`
and `searchText`, i.e. once per keystroke while editing a note or searching.
Each fire runs the full pipeline: rebuild the row array, LCS diff, height
invalidation over all notes (live + archived), and an AppKit view lookup
per row. Separately, every width change during a live resize re-measures
every row (including offscreen ones) through the offscreen measuring host —
the heaviest loop in the stack, run per resize step. Neither cost changes
what the user sees. With a few hundred notes these are the difference
between free keystrokes/resizes and visible lag.

## Current state

(Line numbers are pre-028/035; re-locate by symbol.)

- `Sources/Nickel/Panel/NoteListTable.swift:31-45` — `NoteListTable` holds
  `@EnvironmentObject` store/selection/actions; `updateNSView` calls
  `coordinator.update(store:selection:actions:)`.
- `update(...)` (~:161-200): builds `NoteListRows.rows`, diffs
  (`NoteListDiff.steps`), applies removals/insertions, then
  `noteHeightAnimationIntent()`, `notePendingReveal()` (order matters —
  read the comments), `invalidateChangedRowHeights()`,
  `refreshExistingCells()`, `syncSelectionToTable()`,
  `applyPendingReveal()`, `claimFocusIfNothingHasIt()`.
- `Sources/Nickel/Panel/SelectionModel.swift:52-61` — `@Published
  editingText` and `searchText` live on the same object the table observes.
  NOTE: `searchText` DOES change the rows (filtering) — only `editingText`
  is row-neutral. Per-keystroke search cost is addressed by cheap
  memoization here, not by de-observing.
- `invalidateChangedRowHeights` (~:426-440): walks ALL `store.notes`
  building `[UUID: Note]`, compares to `lastNotesByID`, marks stale, and
  filters `rowHeights` by `Set(rows)` — every update.
- `refreshExistingCells` (~:201-213): `tableView.view(atColumn:0,row:makeIfNecessary:false)`
  per row, every update.
- `NoteListTableView.setFrameSize` (~:960-966): calls
  `coordinator.invalidateAllRowHeights()` on every width change. After plan
  028 this marks all rows stale (no wipe). `viewDidEndLiveResize` is not
  currently overridden.
- The editing row's own height during typing is NOT driven by this
  pipeline: the live cell reports settled heights itself
  (`rowHeight(_:didSettleIn:)`), so short-circuiting `editingText` updates
  does not break mid-edit growth. Verify this claim by reading
  `rowHeight(_:didSettleIn:)` and the cell's `layout()`-driven reporting
  before relying on it (STOP condition if false).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | all pass (377+ after prior plans) |
| Probe | `NICKEL_UI_PROBE=1 .build/debug/Nickel` | all checks passed |

## Scope

**In scope**:
- `Sources/Nickel/Panel/NoteListTable.swift`
- `Sources/Nickel/Panel/SelectionModel.swift` (only if adding a revision
  counter or splitting a publisher proves necessary — prefer coordinator-
  side short-circuits first)
- `Sources/Nickel/Store/NoteStore.swift` (a `notesRevision` counter if
  needed)
- `Sources/Nickel/Support/UIProbe.swift` (guards)

**Out of scope**:
- Memoizing `SelectionModel.filteredNotes` across turns (deliberately
  deferred; the anti-staleness design there is documented — touch nothing).
- Cell reuse / `NSTableView` row-view reuse queues.
- Any behavior change observable in the probe's existing checks.

## Git workflow

- Branch: `advisor/036-list-perf-pipeline` from `main`
  (`git checkout -b advisor/036-list-perf-pipeline main`).

## Steps

### Step 1: Cheap early-out in `update(...)`

Compute the new rows, then: if `newRows == rows` AND the selection set,
`editingID`, `expandedIDs`, and store contents relevant to heights are
unchanged since the last update, skip the heavy tail. Mechanism:

- Add `private var lastUpdateStamp: UpdateStamp` where `UpdateStamp` is an
  `Equatable` struct of: `notesRevision` (add a monotonically incremented
  `private(set) var notesRevision: Int` to `NoteStore`, bumped in the same
  `didSet`/mutation path plan 035 used for `notesByID`), `selection.selectedIDs`,
  `selection.editingID`, `selection.expandedIDs`, `selection.isShowingLogbook`,
  `store.activeSection`, `selection.searchText`.
- If `newRows == rows && stamp == lastUpdateStamp` → return after
  `claimFocusIfNothingHasIt()` (keep that; it's cheap and load-bearing on
  first show). `editingText` is deliberately ABSENT from the stamp — that's
  the keystroke short-circuit.
- `invalidateChangedRowHeights`: gate its full walk on
  `store.notesRevision != lastSeenRevision` instead of running every call.

**Verify**: `swift build`; `swift test`; probe → all pass. The probe's
mid-edit typing check (insertText growing the row) MUST still pass — it is
the proof that editing-row growth doesn't depend on the skipped tail.

### Step 2: Coalesce live-resize re-measures

In `NoteListTableView`:

```swift
override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    coordinator?.invalidateAllRowHeights()
}

override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = newSize.width != frame.width
    super.setFrameSize(newSize)
    guard widthChanged else { return }
    if inLiveResize {
        coordinator?.invalidateVisibleRowHeights()   // new, cheap
    } else {
        coordinator?.invalidateAllRowHeights()        // programmatic resizes
    }
}
```

Add `invalidateVisibleRowHeights()` on the coordinator: mark stale only the
rows intersecting `tableView.visibleRect` (`rows(in:)`) plus a ±10-row
overscan, and schedule the flush. Offscreen rows keep their stale-marked
fate for `viewDidEndLiveResize`'s full pass. Rows scrolled to DURING the
resize get measured on demand anyway (`heightOfRow` miss path schedules).

**Verify**: probe → all checks passed (incl. the post-resize settle check
from plan 028). `swift test` green.

### Step 3: Probe guard for the short-circuit

Add a probe check: capture some internal counter of full-pipeline runs
(add a `#if DEBUG`-visible `updateRunCount` / `heavyUpdateRunCount` pair on
the coordinator), drive three `insertText` keystrokes into a live edit, and
`check(heavyUpdateRunCount unchanged, "typing does not run the full list pipeline")`.

**Verify**: `NICKEL_UI_PROBE=1 .build/debug/Nickel` → all checks passed.

## Test plan

Probe checks above; plus existing `NoteListRowsTests`/drag/reveal checks
unchanged. No new XCTests beyond what Step 1's revision counter needs
(assert it bumps on each mutation — one test in `NoteStoreTests`).

## Done criteria

- [ ] `swift build` exit 0, no warnings
- [ ] `swift test` all pass (incl. revision-counter test)
- [ ] Probe all pass, incl. new typing-doesn't-run-pipeline check
- [ ] `plans/README.md` updated

## STOP conditions

- Reading `rowHeight(_:didSettleIn:)` shows editing-row growth DOES depend
  on the update tail — the keystroke short-circuit premise is false; STOP.
- Any existing probe check fails twice after a fix attempt.
- The stamp needs a field not listed here to stay correct — report which
  invariant forced it before adding.

## Maintenance notes

- The stamp is the contract for "what the heavy tail depends on"; any new
  `@Published` input that affects rows/heights MUST be added to it, or a
  probe check will catch the staleness (keep the probe in CI, plan 041).
- Deferred: `filteredNotes` cross-turn memoization; revisit only with
  profiler evidence.
