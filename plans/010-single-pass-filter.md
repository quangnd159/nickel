# Plan 010: Group filtered notes once per pass instead of re-filtering per section

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- Sources/Nickel/Panel/SelectionModel.swift Sources/Nickel/Panel/PanelView.swift`
> On changes to either, re-verify the excerpts; on a mismatch, STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 005-selection-actions-tests.md (locks `visibleOrder`/filter behavior first)
- **Category**: perf
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

With N notes and S sections, each render pass — including every keystroke in
the search field — runs the locale-aware substring filter over all N notes
once per section (`notes(in:)` calls `filteredNotes` each time), plus once
per section again inside `visibleOrder`. That's O(S·N) expensive comparisons
where one O(N) pass suffices. Small at today's scale; trivially fixed by
grouping once.

## Current state

- `Sources/Nickel/Panel/SelectionModel.swift` (lines 107-132):

```swift
var filteredNotes: [Note] {
    guard !searchText.isEmpty else { return store.notes }
    return store.notes.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
}

func notes(in section: String?) -> [Note] {
    filteredNotes.filter { $0.listName == section }
}

var visibleOrder: [UUID] {
    if let activeSection = store.activeSection {
        return notes(in: activeSection).map(\.id)
    }
    var ids = notes(in: nil).map(\.id)
    for sectionName in store.sections {
        ids += notes(in: sectionName).map(\.id)
    }
    return ids
}
```

- Call sites of `notes(in:)` in `PanelView.swift`: line 320
  (`selection.notes(in: nil)`) and line 337
  (`selection.notes(in: sectionName)` inside `ForEach(store.sections)`), plus
  a focused-section branch around line 303 (`items`).
- Design constraint (from the comments at `SelectionModel.swift:74-80,
  118-122`): these are computed on demand, *never cached across mutations*,
  so rendering and selection can't observe different snapshots. Keep that —
  this plan removes redundant work within one derivation, it does not
  introduce stored/cached state.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | all pass            |

## Scope

**In scope**:
- `Sources/Nickel/Panel/SelectionModel.swift`

**Out of scope**:
- `PanelView.swift` — call sites keep calling `notes(in:)`; only the
  internals get cheaper. (Threading a grouped dictionary through the view
  was considered and rejected: it complicates the view for negligible extra
  gain at this scale.)
- Any `@Published` cached copy of the filter result — explicitly rejected
  per the design comments quoted above.

## Git workflow

- Branch: `advisor/010-single-pass-filter`
- One commit, imperative message (e.g. "Derive visible order from one grouped filter pass").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a grouped derivation and use it in `visibleOrder`

In `SelectionModel`, add:

```swift
/// One filter pass, grouped by section. Computed on demand like
/// `filteredNotes` — never stored — so it can't lag the store.
var filteredNotesBySection: [String?: [Note]] {
    Dictionary(grouping: filteredNotes, by: \.listName)
}
```

Rewrite `visibleOrder` to compute `let grouped = filteredNotesBySection`
once and index into it (`grouped[activeSection] ?? []`, `grouped[nil] ?? []`,
`grouped[sectionName] ?? []`), and rewrite `notes(in:)` as
`filteredNotesBySection[section] ?? []`. Note `Dictionary(grouping:)`
preserves element order within each group, so per-section order is unchanged.

**Verify**: `swift build` → exit 0.

### Step 2: Run the behavior net

Plan 005's `SelectionModelTests` pin `visibleOrder` ordering (ungrouped
first, then sections in `store.sections` order) and filter/selection
survival; they must pass unchanged.

**Verify**: `swift test` → all pass.

## Test plan

No new tests — Plan 005's suite is the contract. If Plan 005 has not landed
yet, STOP (dependency).

## Done criteria

- [ ] `swift build` exits 0; `swift test` all pass (incl. `SelectionModelTests`)
- [ ] `visibleOrder` performs exactly one `filteredNotes` evaluation per call
      (read the code: one `filteredNotesBySection` access)
- [ ] No new stored/`@Published` state added to `SelectionModel`
- [ ] `git status` shows only `SelectionModel.swift` modified (plus plans index)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `SelectionModelTests` does not exist (Plan 005 not landed).
- Any ordering test fails after the rewrite — grouping changed observable
  order; report rather than patching the test.

## Maintenance notes

- `notes(in:)` still evaluates the grouped dictionary per call; the win is
  inside `visibleOrder` and the removal of the double filter. If profiling
  ever shows the per-call grouping matters, the next step is passing the
  grouped dictionary down from `PanelView` — deliberately deferred.
- Reviewer: confirm no snapshot/caching crept in (the design comments forbid it).
