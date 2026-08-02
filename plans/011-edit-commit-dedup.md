# Plan 011: Deduplicate the edit-commit logic between NoteRow and PanelActions

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- Sources/Nickel/Panel/NoteRow.swift Sources/Nickel/Panel/PanelActions.swift`
> On any change, re-verify the excerpts; on a mismatch, STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 005-selection-actions-tests.md (pins `commitActiveEditIfAny` behavior)
- **Category**: tech-debt
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

The "write the edit buffer to the store, then exit edit mode" sequence exists
twice with subtly different guards. Any future change to commit semantics
(trimming, no-op on unchanged text, validation) must be made in both places
or they silently diverge. One should forward to the other.

## Current state

- `Sources/Nickel/Panel/NoteRow.swift`:
  - Environment objects at lines 17-19 include
    `@EnvironmentObject private var actions: PanelActions` (verified — no
    wiring needed).
  - `commitEdit()` (lines 297-301):

```swift
private func commitEdit() {
    guard isEditing else { return }
    store.update(id: note.id, text: selection.editingText)
    selection.endEditing()
}
```

  - Called from lines 324 and 338 (focus-loss / Return handling).
  - `isEditing` is true iff `selection.editingID == note.id` — so inside the
    guard, `note.id == selection.editingID`.
- `Sources/Nickel/Panel/PanelActions.swift`, `commitActiveEditIfAny()`
  (lines 84-88):

```swift
func commitActiveEditIfAny() {
    guard let id = selection.editingID else { return }
    store.update(id: id, text: selection.editingText)
    selection.endEditing()
}
```

- Equivalence argument (the review point): when `isEditing` is true,
  `selection.editingID == note.id`, so forwarding produces the identical
  `store.update(id: note.id, …)` call. Keeping `NoteRow`'s `guard isEditing`
  preserves the exact no-op behavior when this row isn't the one editing.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | all pass            |

## Scope

**In scope**:
- `Sources/Nickel/Panel/NoteRow.swift` (only `commitEdit()`)

**Out of scope**:
- `PanelActions.swift` — `commitActiveEditIfAny()` is the canonical copy;
  unchanged.
- The call sites at NoteRow lines 324/338 and any focus/keyboard handling.

## Git workflow

- Branch: `advisor/011-edit-commit-dedup`
- One commit, imperative message (e.g. "Forward NoteRow edit commit to PanelActions").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Forward the row commit

Replace `commitEdit()`'s body:

```swift
private func commitEdit() {
    guard isEditing else { return }
    actions.commitActiveEditIfAny()
}
```

**Verify**: `swift build` → exit 0.

### Step 2: Run the suite

Plan 005's `PanelActionsTests` cover `commitActiveEditIfAny`; the whole
suite must stay green.

**Verify**: `swift test` → all pass.

## Test plan

No new tests; Plan 005's coverage of `commitActiveEditIfAny` now covers the
single canonical implementation.

## Done criteria

- [ ] `swift build` exits 0; `swift test` all pass
- [ ] `grep -n "store.update" Sources/Nickel/Panel/NoteRow.swift` → no matches
- [ ] `git status` shows only `NoteRow.swift` modified (plus plans index)
- [ ] `plans/README.md` status row updated

## STOP conditions

- Either excerpt no longer matches (the guards or bodies changed).
- `isEditing`'s definition in `NoteRow` is no longer
  "`selection.editingID == note.id`" — the equivalence argument collapses;
  report instead of adapting.

## Maintenance notes

- Future commit-semantics changes (trimming, dirty-check) now go in exactly
  one place: `PanelActions.commitActiveEditIfAny()`.
- Reviewer: this is a 2-line change; the only thing to check is the
  equivalence argument above.
