# Plan 024: Cut per-row and per-render O(N) rebuilds in the note list

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 83d0b46..HEAD -- Sources/Nickel/Panel/PanelActions.swift Sources/Nickel/Panel/PanelView.swift Sources/Nickel/Panel/SelectionModel.swift Tests/NickelTests/PanelActionsTests.swift`
> Plan 023 edits `SelectionModel.filteredNotes` (adds attachment-filename
> matching) — that drift is expected. If `PanelActions.notes(for:)` /
> `allSelectedAreDone` or `PanelView`'s `noteList` differ structurally from
> the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (menu labels and list rendering must stay live-accurate)
- **Depends on**: plans/023-search-attachment-notes.md (soft — same file; execute in order)
- **Category**: perf
- **Planned at**: commit `83d0b46`, 2026-08-02

## Why this matters

The note list is a deliberate plain `VStack` (documented decision — see the
comment at `PanelView.swift:312-318`; do NOT change it), so every store
mutation or search keystroke re-evaluates all N rows. Two costs multiply
with that:

1. Each `NoteRow`'s context-menu content reads
   `actions.allSelectedAreDone`, which builds a full `[UUID: Note]`
   dictionary of the whole store *per row* — and that dictionary
   constructor, `Dictionary(uniqueKeysWithValues:)`, also **traps** (hard
   crash) if `notes.json` was hand-edited to contain two notes with the
   same id (the file is user-facing via "Reveal Notes in Finder").
2. `PanelView`'s Show All list calls `selection.notes(in:)` once per
   section plus `visibleOrder` twice more — each call regrouping the entire
   filtered store — so one render does `sections + 3` full filter passes,
   each running locale-aware `localizedCaseInsensitiveContains` per note
   while searching.

At a few dozen notes this is invisible; at a few thousand it's a quadratic
wall on every keystroke. Both fixes are local and preserve the
"computed, never stored" freshness invariants documented in the code.

## Current state

SwiftPM, macOS 14+, AppKit + SwiftUI, XCTest.

`PanelActions` (`Sources/Nickel/Panel/PanelActions.swift:16-39`):

```swift
/// The selected notes, in visible (not selection-insertion) order.
private var selectedNotes: [Note] {
    notes(for: selection.visibleOrder.filter { selection.selectedIDs.contains($0) })
}

/// All currently-visible notes, in visible order.
private var allVisibleNotes: [Note] {
    notes(for: selection.visibleOrder)
}

private func notes(for ids: [UUID]) -> [Note] {
    let byID = Dictionary(uniqueKeysWithValues: store.notes.map { ($0.id, $0) })
    return ids.compactMap { byID[$0] }
}

var allSelectedAreDone: Bool {
    let notes = selectedNotes
    return !notes.isEmpty && notes.allSatisfy(\.isDone)
}
```

`NoteRow` attaches the menu inside `body` (`Sources/Nickel/Panel/NoteRow.swift:109`):
`.contextMenu { contextMenuContent }`, and `contextMenuContent` reads
`actions.allSelectedAreDone` / `actions.allSelectedAreExpanded`
(`NoteRow.swift:369-380`).

`SelectionModel` grouping (`Sources/Nickel/Panel/SelectionModel.swift:112-139`):

```swift
var filteredNotesBySection: [String?: [Note]] {
    Dictionary(grouping: filteredNotes, by: \.listName)
}

func notes(in section: String?) -> [Note] {
    filteredNotesBySection[section] ?? []
}

var visibleOrder: [UUID] {
    let grouped = filteredNotesBySection
    if let activeSection = store.activeSection {
        return (grouped[activeSection] ?? []).map(\.id)
    }
    var ids = (grouped[String?.none] ?? []).map(\.id)
    for sectionName in store.sections {
        ids += (grouped[sectionName] ?? []).map(\.id)
    }
    return ids
}
```

`PanelView`'s Show All branch (`Sources/Nickel/Panel/PanelView.swift:319-352`,
abridged):

```swift
VStack(alignment: .leading, spacing: 10) {
    ForEach(selection.notes(in: nil)) { note in ... }
    ForEach(store.sections, id: \.self) { sectionName in
        sectionHeader(sectionName)...
        ForEach(selection.notes(in: sectionName)) { note in ... }
    }
}
.transition(sectionSwitchTransition)
.animation(rowSpring, value: selection.visibleOrder)
.animation(rowSpring, value: selection.expandedIDs)
```

(There is a second `.animation(..., value: selection.visibleOrder)` /
related modifier just below — read the live code around lines 344-360.)

Documented invariants to preserve (they are comments in the code):
`filteredNotesBySection` "Computed on demand … never stored — so it can't
lag the store" (`SelectionModel.swift:112-113`), and `visibleOrder`
"Computed on demand (not cached)" (`SelectionModel.swift:127-128`). The fix
must not introduce stored caches on `SelectionModel`; locals inside a single
render pass are fine.

Tests: `Tests/NickelTests/PanelActionsTests.swift` drives `PanelActions`
against a real temp-directory store — model new tests on it.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | exit 0, all pass    |

## Scope

**In scope**:
- `Sources/Nickel/Panel/PanelActions.swift`
- `Sources/Nickel/Panel/PanelView.swift` (only the `noteList` body)
- `Tests/NickelTests/PanelActionsTests.swift`
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `SelectionModel` itself — no stored caches, no API changes beyond reading
  it (plan 023 owns its only change this round).
- Switching `VStack` → `LazyVStack` (documented deliberate decision).
- `NoteRow.swift` — the menu stays where it is; we make what it reads cheap.

## Git workflow

- Branch: `advisor/024-render-pass-efficiency`
- Commit style: short imperative subject, e.g. "Stop rebuilding whole-store dictionaries per note row".
- Do NOT push or open a PR.

## Steps

### Step 1: Make the per-row reads allocation-free and trap-free

In `PanelActions.swift`:

1. Replace the trapping constructor in `notes(for:)` with the
   duplicate-tolerant one (first occurrence wins):

```swift
private func notes(for ids: [UUID]) -> [Note] {
    let byID = Dictionary(store.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return ids.compactMap { byID[$0] }
}
```

2. Recompute `allSelectedAreDone` without any dictionary or ordering work —
   it only needs membership, not visible order:

```swift
var allSelectedAreDone: Bool {
    let ids = selection.selectedIDs
    guard !ids.isEmpty else { return false }
    var sawAny = false
    for note in store.notes where ids.contains(note.id) {
        if !note.isDone { return false }
        sawAny = true
    }
    return sawAny
}
```

(`allSelectedAreExpanded` already works off sets — leave it.)
`selectedNotes` / `allVisibleNotes` keep using `notes(for:)`; they run on
user-triggered actions (copy/merge/delete), not per row.

**Verify**: `swift test --filter PanelActionsTests` → all pass.

### Step 2: One grouping per render in PanelView's Show All branch

In `noteList`, bind the grouping once and index it, instead of calling
`selection.notes(in:)` per section:

```swift
let grouped = selection.filteredNotesBySection
VStack(alignment: .leading, spacing: 10) {
    ForEach(grouped[String?.none] ?? []) { note in ... }
    ForEach(store.sections, id: \.self) { sectionName in
        sectionHeader(sectionName)...
        ForEach(grouped[sectionName] ?? []) { note in ... }
    }
}
```

`let` bindings are legal inside a `@ViewBuilder`. Keep every modifier
(`.transition`, both/all `.animation(value:)` lines) byte-identical — the
`.animation(value: selection.visibleOrder)` calls stay as they are (each is
one extra pass; acceptable, and changing animation keys risks visual
regressions). If the focused-section branch (when `store.activeSection` is
set) has the same per-call pattern, apply the same single-binding treatment
there.

**Verify**: `swift build` → exit 0; `swift test` → all pass.

### Step 3: Duplicate-id regression test

In `PanelActionsTests.swift`, add
`testActionsSurviveDuplicateNoteIDsInStore`: hand-write a v2 store JSON file
containing two notes with the **same** `id` (build the JSON by encoding one
note and duplicating the object in the array string, or by writing the file
manually — see how existing corruption tests in `NoteStoreTests.swift`
construct raw JSON), load a `NoteStore(fileURL:)` on it, build
`SelectionModel` + `PanelActions`, select-all
(`selection.selectedIDs = Set(store.notes.map(\.id))` or via its API), and
assert `allSelectedAreDone` and `copy()`-adjacent accessors do not crash
(calling `allSelectedAreDone` and `allVisibleNotes`-backed behavior through
a public action is enough — the old code trapped in `notes(for:)`).

Note: `copy()` writes to the real general pasteboard; prefer asserting via
`allSelectedAreDone` plus `toggleDone()`/`merge()`-safe paths that don't
touch `NSPasteboard`. The point is: no trap with duplicate ids.

**Verify**: `swift test --filter PanelActionsTests` → all pass. Before the
step-1 change this test would crash the test runner; if you want proof,
stash step 1, observe the crash, unstash.

## Test plan

- Step 3's duplicate-id test (regression for the trap).
- Existing `PanelActionsTests` pin `allSelectedAreDone` semantics
  (empty selection → false; mixed → false; all done → true) — if no such
  cases exist, add them, since step 1 rewrites that property.
- Rendering change (step 2) has no test harness; the gate is the build plus
  existing SelectionModel/PanelActions suites, and the reviewer's read.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0; duplicate-id test passes
- [ ] `grep -n "uniqueKeysWithValues" Sources/Nickel/Panel/PanelActions.swift` → no matches
- [ ] `grep -n "selection.notes(in:" Sources/Nickel/Panel/PanelView.swift` → no matches in the Show All branch (grouped local used instead)
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- The excerpts don't match (beyond plan 023's `filteredNotes` change).
- Step 2's `let grouped` binding produces a compiler error inside the
  `@ViewBuilder` context that you cannot resolve by hoisting it into the
  enclosing function/property scope — report the exact error; do not
  restructure `noteList` further.
- Any visual/animation modifier has to change to make step 2 compile.

## Maintenance notes

- Reviewer: the "Mark as Done"/"Mark as Not Done" context-menu label must
  still flip correctly right after toggling done state (that's what the
  per-row read was paying for — verify by hand once in the running app).
- If the list ever moves to sectioned data owned by `PanelView` state,
  revisit `visibleOrder`'s remaining recomputations then; deliberately not
  cached now to honor the "never stored" invariant.
- The duplicate-tolerant dictionary quietly keeps the first of two
  duplicate-id notes; a proper load-time dedupe in `NoteStore.repaired` was
  considered and left out of scope (S follow-up if it ever matters).
