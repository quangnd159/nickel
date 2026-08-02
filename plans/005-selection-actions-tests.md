# Plan 005: Add SelectionModel and PanelActions test suites

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- Sources/Nickel/Panel/SelectionModel.swift Sources/Nickel/Panel/PanelActions.swift Tests/NickelTests/`
> On any change to those two source files, re-verify the "Current state"
> excerpts; on a mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

`SelectionModel` (263 lines: shift/command click handling, range extension,
arrow-key navigation over the filtered visible order) and `PanelActions`
(165 lines: destructive multi-select delete/merge, next-selection math) are
among the highest-churn files in the repo and are exactly the index/set logic
where off-by-one and stale-ID bugs live. Both are plain `ObservableObject`s
constructed from a `NoteStore` — unit-testable today with no SwiftUI.

## Current state

- `Sources/Nickel/Panel/SelectionModel.swift`:
  - `init(store: NoteStore)` (line 71) subscribes to `store.$notes` and
    prunes `selectedIDs`/anchor/lead/editing to still-existing notes
    (`pruneToExisting`, lines 88-99).
  - `filteredNotes` (line 107): case-insensitive substring filter on
    `searchText`. `notes(in:)` (line 114) scopes by `listName`.
  - `visibleOrder` (line 123): active section's notes only, else ungrouped
    notes first then each section's notes in `store.sections` order.
  - `handleClick(on:shift:command:)` (line 138): shift extends from
    `anchorID` (falling back to `selectSingle` when no anchor), command
    toggles, plain click selects single.
  - `extendRange(to:)` (line 168): selects the inclusive range between
    anchor and target in `visibleOrder`; anchor stays put; `leadID` moves.
  - `moveSelection(direction:extend:)` (line 192): steps from
    `leadID ?? anchorID ?? selectedIDs.first`, clamps to the ends; with no
    resolvable reference selects first (down) or last (up).
  - `selectAllNotes()` (line 257), `toggleExpanded(ids:)` (line 246,
    all-or-nothing group toggle).
- `Sources/Nickel/Panel/PanelActions.swift`:
  - `init(store:selection:)` (line 11).
  - `delete()` (lines 106-135): snapshots `selectedIDs` and `visibleOrder`
    *before* mutating (the prune races otherwise), deletes, then selects the
    first survivor after the last deleted index, else the last survivor
    before the first deleted index, else clears.
  - `merge()` (lines 90-99): requires ≥ 2 selected; survivor is the
    earliest-`createdAt` note; selects it afterwards.
  - `commitActiveEditIfAny()` (lines 84-88): writes `editingText` to the
    store for `editingID`, then `endEditing()`.
  - `copy()`/`copyAsList()`/`copyAllAsList()` write to the real system
    pasteboard via `PasteboardWriter` — do NOT test these (they'd clobber
    the developer's clipboard; out of scope).
- Test exemplar: `Tests/NickelTests/NoteStoreTests.swift` — temp-dir
  `NoteStore(fileURL:)` fixture in `setUp` (lines 9-23). Reuse that pattern;
  build `SelectionModel(store:)` and `PanelActions(store:selection:)` on top.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | all pass            |

## Scope

**In scope**:
- `Tests/NickelTests/SelectionModelTests.swift` (create)
- `Tests/NickelTests/PanelActionsTests.swift` (create)

**Out of scope**:
- Both source files — characterization only; bugs found are reported, not fixed.
- `PasteboardWriter` and the `copy*` actions (real-pasteboard side effects).

## Git workflow

- Branch: `advisor/005-selection-actions-tests`
- One commit, imperative message (e.g. "Add SelectionModel and PanelActions tests").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: SelectionModelTests

Fixture: temp-dir store + `SelectionModel(store:)`; add notes via
`store.add(text:sourceApp:)` and read IDs from `store.notes`. Tests:

1. Plain click selects single; second click on another note replaces.
2. Command-click toggles membership without clearing others.
3. Shift-click with an anchor selects the inclusive range in `visibleOrder`;
   a further shift-click extends from the *same* anchor.
4. Shift-click with no prior anchor behaves as select-single.
5. `moveSelection(direction: 1, extend: false)` steps down; clamps at the
   last note (repeated calls don't wrap).
6. `moveSelection(extend: true)` grows the range past the anchor's immediate
   neighbor on repeated calls (regression for the `leadID` behavior —
   see the comment at `SelectionModel.swift:65-69`).
7. With `searchText` set, `visibleOrder` contains only matching notes, and
   selection of a note hidden by the filter *survives* (see comment at
   lines 74-80): set selection, set `searchText` to exclude it, assert
   still selected; clear search, still selected.
8. Deleting a selected note from the store prunes it from `selectedIDs`
   (and ends editing if it was the editing note).
9. `visibleOrder` with an `activeSection` contains only that section's notes;
   with none, ungrouped first then sections in order.
10. `selectAllNotes` selects everything visible; anchor = first, lead = last
    (assert via a subsequent `moveSelection(extend: true)` stepping from the
    last note).

### Step 2: PanelActionsTests

Fixture adds `PanelActions(store:selection:)`. Tests:

1. `delete()` with a middle note selected selects the following note.
2. `delete()` of the last note selects the new last (preceding survivor).
3. `delete()` of everything clears the selection.
4. `delete()` of a non-contiguous multi-selection selects the survivor after
   the *last* deleted index.
5. `merge()` keeps the earliest-created note and selects it.
6. `merge()` with fewer than 2 selected is a no-op.
7. `commitActiveEditIfAny()` writes the edit buffer to the store and clears
   editing state; with no active edit it's a no-op.
8. `toggleDone()` toggles exactly the selection.

**Verify**: `swift test --filter SelectionModelTests && swift test --filter PanelActionsTests` → all pass.

## Test plan

Steps 1-2 (≥ 18 new tests), modeled on `NoteStoreTests.swift`.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0 with the two new suites present and passing
- [ ] No test touches `NSPasteboard`
- [ ] `git status` shows only the two new test files (plus the plans index)
- [ ] `plans/README.md` status row updated

## STOP conditions

- A test exposes a real selection/deletion bug (e.g. next-selection lands on
  a deleted ID) — report it; don't fix production code here.
- `SelectionModel`'s Combine subscription doesn't fire synchronously in tests
  (prune assertions flaky) — report rather than adding waits/sleeps.

## Maintenance notes

- These suites are the safety net for any future refactor of `PanelView` or
  selection logic; keep them green in Plans that touch `Panel/`.
- Reviewer: check tests read IDs from the store rather than assuming
  insertion order beyond what `add` guarantees (append).
