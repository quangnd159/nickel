# Plan 026: Bounds-guard every table callback that indexes `rows`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/Panel/NoteListTable.swift Sources/Nickel/Support/UIProbe.swift`
> If either file changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

The note list is a view-based `NSTableView` whose data source keeps its row
model in `NoteListCoordinator.rows`. During a drag (`.gap` drop feedback
opens a phantom gap row) and during animated removals, AppKit asks the
delegate about row indices that are outside the current model. One callback
(`heightOfRow`) already guards for this and documents why; four others index
`rows` raw. Any out-of-range ask there is an index-out-of-range trap — a hard
crash mid-drag. This plan makes every callback safe and pins the invariant in
the UI probe.

## Current state

- `Sources/Nickel/Panel/NoteListTable.swift` — the entire list stack: the
  `NoteListCoordinator` (data source + delegate) and `NoteListTableView`.
- The guarded exemplar, `NoteListTable.swift:352-357`:

```swift
func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    // Out of range without scheduling anything: the table asks about rows
    // that aren't in the model while `.gap` feedback opens a drop gap
    // mid-drag, and measuring in response would put a layout pass in the
    // middle of a drag for a row that doesn't exist.
    guard rows.indices.contains(row) else { return Self.provisionalRowHeight }
```

- The unguarded callbacks, `NoteListTable.swift:865-871`:

```swift
func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
    !rows[row].isSelectable
}

func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    rows[row].isSelectable
}
```

- `tableView(_:rowViewForRow:)` and `tableView(_:viewFor:row:)` around
  `NoteListTable.swift:875-895` — `viewFor` indexes `rows[row]` (twice; once
  for content, once for `isInteractive`).
- The selection write-back, `NoteListTable.swift:603-607`:

```swift
func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isSyncingSelection, selection != nil else { return }
    let ids = tableView.selectedRowIndexes.compactMap { rows[$0].noteID }
    selection.selectedIDs = Set(ids)
}
```

- Also audit-flagged, same fix family: `pointInRow` at
  `NoteListTable.swift:968-972` derives click coordinates from
  `rect(ofRow:)`, but checkbox hit-testing (`NoteRowMetrics.checkboxColumnWidth`)
  and `cell.attachmentFrames` are expressed in the *cell's* coordinate space,
  and the `.fullWidth` table style insets cells horizontally inside the row
  (the probe prints `tableWidth=311 cellWidth=299`). Whether the *origins*
  differ is unverified — this plan only adds a probe assertion to answer it,
  not a behavior change.
- Repo conventions: doc comments explain *why* a guard exists (see the
  `heightOfRow` excerpt); match that. Verification harness:
  `NICKEL_UI_PROBE=1 .build/debug/Nickel` runs offscreen geometry checks in
  `Sources/Nickel/Support/UIProbe.swift`; individual checks are private
  `check<Name>` funcs calling `check(_ condition: Bool, _ description: String)`
  (`UIProbe.swift:666`), invoked from `run(panel:store:)` (`UIProbe.swift:73`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | 377 tests, 0 failures |
| Geometry probe | `NICKEL_UI_PROBE=1 .build/debug/Nickel` | prints `UIProbe: all checks passed`, exit 0 |

## Scope

**In scope** (the only files you should modify):
- `Sources/Nickel/Panel/NoteListTable.swift`
- `Sources/Nickel/Support/UIProbe.swift`

**Out of scope** (do NOT touch):
- `heightOfRow` — already guarded; leave as is.
- Any change to `pointInRow`'s math or click handling — this plan only adds
  the probe assertion that measures whether row-rect and cell origins differ.
  If the probe shows a real offset, report it in your final message; the fix
  is a separate decision.
- `NoteListDiff`, `NoteListRows`, drag/drop logic.

## Git workflow

- Branch: `advisor/026-guard-table-callbacks` from `main`
  (`git checkout -b advisor/026-guard-table-callbacks main` — run this
  explicitly; worktrees have forked from stale HEADs before).
- Commit style: imperative summary line, body explains why (see `git log`).

## Steps

### Step 1: Guard the four callbacks

In `NoteListTable.swift`:

- `isGroupRow`: `guard rows.indices.contains(row) else { return false }`
- `shouldSelectRow`: `guard rows.indices.contains(row) else { return false }`
- `viewFor`: `guard rows.indices.contains(row) else { return nil }`
- `tableViewSelectionDidChange`: replace `rows[$0].noteID` with a
  bounds-checked map: `rows.indices.contains($0) ? rows[$0].noteID : nil`.

Each guard gets a one-line comment pointing at the `heightOfRow` comment as
the reason (e.g. `// Same out-of-model ask as heightOfRow documents.`) —
do not duplicate the full paragraph four times.

**Verify**: `swift build` → exit 0, no warnings.

### Step 2: Probe assertions

In `UIProbe.swift`, add a `checkDelegateGuards(table:)` private func, called
from `run(panel:store:)` after the existing checks. It must:

1. Call `table.delegate!.tableView!(table, isGroupRow: rowCount)` and
   `(…, isGroupRow: rowCount + 1)` where `rowCount = table.numberOfRows`,
   asserting they return `false` without trapping. Same for
   `shouldSelectRow` (expect `false`) and the data-source `viewFor`
   equivalent via `table.delegate!.tableView!(table, viewFor: table.tableColumns[0], row: rowCount)`
   (expect `nil`). Use the same `check(_:_)` reporting helper as the other
   checks.
2. Assert coordinate-space agreement: for the first note row,
   `abs(table.rect(ofRow: r).minX - table.frameOfCell(atColumn: 0, row: r).minX)`
   — record the delta with a `check(delta < 0.5, "row rect and cell frame share an x-origin (delta \(delta))")`.
   If this check FAILS, do not change `pointInRow`; keep the failing check
   out of the committed probe (convert it to a printed measurement instead)
   and report the measured delta in your final message.

**Verify**: `NICKEL_UI_PROBE=1 .build/debug/Nickel` → all checks passed,
including the new ones (or the origin measurement printed, per above).

## Test plan

No XCTest changes: the guards are only observable through live-table asks,
which is what the probe covers. Existing 377 tests must stay green.

## Done criteria

- [ ] `swift build` exits 0 with no warnings
- [ ] `swift test` → 377 passing
- [ ] `NICKEL_UI_PROBE=1 .build/debug/Nickel` exits 0; out-of-range delegate
      asks are exercised by a new check
- [ ] `grep -n "rows\[row\]" Sources/Nickel/Panel/NoteListTable.swift` shows
      no unguarded use inside `isGroupRow`/`shouldSelectRow`/`viewFor`
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The excerpts above don't match the live code (drift).
- The probe crashes when asking out-of-range — that means the trap is real
  and reachable in the probe environment; the guards are then the fix, but
  if the crash persists AFTER Step 1, stop and report.
- The x-origin delta exceeds 0.5pt: report the measurement; do not fix.

## Maintenance notes

- Any new `NSTableViewDataSource`/`Delegate` method added later must follow
  the same guard convention; reviewers should check for raw `rows[row]`.
- If the origin delta turns out nonzero, the follow-up is switching
  `pointInRow` to `frameOfCell(atColumn:0,row:)` — a separate plan.
