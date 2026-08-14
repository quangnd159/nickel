# Plan 040: Test the section palette's logic and the note context menu

> **Executor instructions**: Follow this plan step by step, verifying each
> step. On any STOP condition, stop and report. Update this plan's row in
> `plans/README.md` when done — unless a reviewer told you they maintain the
> index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/Panel/SectionSwitcher.swift Sources/Nickel/Panel/NoteContextMenu.swift Sources/Nickel/Panel/CommandPalette.swift`
> Plan 039 deletes `sectionHeaderMenu` from NoteContextMenu — expected.
> Verify the excerpts at their symbols; a missing mechanism = STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/039-menu-shortcut-consolidation.md (soft — 039
  edits NoteContextMenu; land it first to avoid conflicts)
- **Category**: tests
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

The two highest-churn, zero-coverage user surfaces:

1. `SectionSwitcher` (528 lines) is the ⌘K/⌃⌘M palette — the code behind
   the recent "accidental move" fix. Its result-building, checkmark logic
   (including a subtle `String??` double-optional), and commit dispatch are
   `private` members of the View, so none of it is tested. A regression
   here re-ships the exact bug class the split fixed, silently.
2. `NoteContextMenu` (140 lines) replaced the SwiftUI context menu during
   the table refactor; its per-item enablement rules are pure functions of
   `(store, selection)` that nothing pins.

The repo already contains the pattern to follow for (1):
`CommandPalette.swift`'s `PaletteMatcher` is an extracted pure enum with
its own suite (`Tests/NickelTests/CommandPaletteTests.swift`, 233 lines).

## Current state

- `Sources/Nickel/Panel/SectionSwitcher.swift`:
  - `results` (~:246-260) builds the candidate list:

```swift
var candidates: [Result] = [move ? .noSection : .showAll]
candidates += store.sections.map { .section($0) }
candidates += PaletteCommand.applicable(in: paletteContext).map { .command($0) }
var items = PaletteMatcher.ranked(candidates, query: trimmedQuery, group: { $0.group }, label: { label(for: $0) })
// then a "New Section" row when the query matches no existing section
```

  - `uniformSelectionSection` (~:315-318) — the `String??`:

```swift
private var uniformSelectionSection: String?? {
    let sections = Set(store.activeNotes.filter { selection.selectedIDs.contains($0.id) }.map(\.listName))
    return sections.count == 1 ? sections.first : nil
}
```

  - `isActive(_:)` (~:320-334) — move-mode checkmark from
    `uniformSelectionSection`; switch-mode from `store.activeSection`.
  - `commit(_:)` (~:339-395) — move mode calls `actions.move(toSection:)`;
    switch mode calls `selection.setShowingLogbook(false)` +
    `store.setActiveSection`/`createSection`; command rows dismiss-then-run.
  - `Result` is a private enum inside the View (check exact shape:
    `.showAll`, `.section(String)`, `.noSection`, `.newSection(String)`,
    `.command(PaletteCommand)`).
- `Sources/Nickel/Panel/NoteContextMenu.swift:30-60` — enablement examples:
  toggle-done title flips on `actions.allSelectedAreDone`; Edit items
  `enabled: selection.selectedIDs.count == 1`; Merge `>= 2`; the Move
  submenu (`autoenablesItems = false`) lists sections + "No Section"; a
  clear-done item is gated on `hasDone` computed from `store.activeNotes`
  (~:100). Menus are built synchronously by a static func — inspectable
  without a running app.
- Exemplar extraction: `Sources/Nickel/Panel/CommandPalette.swift:35`
  `enum PaletteMatcher` + `CommandPaletteTests.swift`.
- Test infra: `Tests/NickelTests/` uses `NoteStore` fixtures via env-path
  overrides; `PanelActionsTests.swift` shows store+selection+actions
  assembly.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | all pass, count grows |

## Scope

**In scope**:
- `Sources/Nickel/Panel/SectionSwitcher.swift` (extraction refactor ONLY —
  behavior identical)
- `Tests/NickelTests/SectionSwitcherLogicTests.swift` (new)
- `Tests/NickelTests/NoteContextMenuTests.swift` (new)

**Out of scope**:
- Any behavior change whatsoever; this is lift-and-test.
- The palette's View layer (focus, key handling, appearance).
- `PaletteMatcher`/`PaletteCommand` (already tested).

## Git workflow

- Branch: `advisor/040-palette-and-menu-tests` from `main`
  (`git checkout -b advisor/040-palette-and-menu-tests main`).

## Steps

### Step 1: Extract the palette's pure logic

Create `enum SectionSwitcherLogic` (same file or a sibling — same file
keeps the private `Result` reachable; PREFER moving `Result` +
`SectionSwitcherLogic` into a new `Sources/Nickel/Panel/SectionSwitcherLogic.swift`
with internal visibility, mirroring how `PaletteMatcher` lives apart from
its view). Move, as static pure functions taking explicit inputs (sections,
activeSection, selectedIDs→listName mapping, move flag, query, palette
context):

- `results(...) -> [Result]` (the candidate build + ranked + New Section
  append),
- `uniformSelectionSection(...) -> String??`,
- `isActive(...) -> Bool`.

The View keeps thin computed wrappers calling these with its live state.
`commit` stays in the View (it performs side effects) but reduce it to a
`switch` over a new pure `commitAction(for: Result, move: Bool) ->
CommitAction` enum (`.move(to: String?)`, `.switchTo(String?)`,
`.create(String)`, `.moveCreate(String)`, `.run(PaletteCommand)`) — the
pure mapping is what gets tested; the View executes the action.

**Verify**: `swift build` → exit 0; `swift test` → all previously passing
tests still pass (no behavior change).

### Step 2: Palette tests

`SectionSwitcherLogicTests.swift`, covering at minimum:
- switch mode: first row is Show All; sections ranked by query; New
  Section appears only for a non-matching non-empty query; commands appear
  only in switch mode.
- move mode: first row is No Section; no command rows ever.
- `uniformSelectionSection`: uniform → `.some(.some(name))`; uniform
  ungrouped → `.some(.none)`; mixed → `nil`; empty selection → nil.
- `isActive`: move-mode checkmark on the uniform section / No Section;
  switch-mode checkmark follows activeSection; New Section never active.
- `commitAction`: every `Result` × move flag maps to the expected action
  (the accidental-move regression pin: switch mode NEVER yields `.move`).

### Step 3: Context-menu tests

`NoteContextMenuTests.swift`: build menus via the static entry point with
fixture store/selection/actions and assert `title`/`isEnabled`:
- 0 / 1 / 2 selected: Edit and Edit in New Window enabled only at 1;
  Merge only at ≥2.
- All-done selection → "Mark as Not Done" title; mixed → "Mark as Done".
- Move submenu lists every section + "No Section".
- Logbook mode: assert whatever the current builder produces for
  mode `.logbook` (read the code; pin the current behavior).

**Verify**: `swift test` → all pass; report the new total.

## Test plan

As Steps 2–3; target ≥ 20 new tests combined. Keep them table-driven where
natural.

## Done criteria

- [ ] `swift build` exit 0, no warnings
- [ ] `swift test` all pass; ≥ 20 new tests
- [ ] `SectionSwitcher.swift` shrank (logic moved out); View behavior
      unchanged (existing UI-adjacent tests + probe green)
- [ ] `NICKEL_UI_PROBE=1 .build/debug/Nickel` → all checks passed
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails at symbol level.
- The extraction forces a visibility change on `PaletteCommand`/context
  types that ripples beyond the two files — report before widening API.
- Any existing test fails after the extraction (behavior changed) — revert
  the offending move and report.

## Maintenance notes

- New palette result kinds must come with `commitAction` mapping tests —
  that mapping is the accidental-move regression net.
- Reviewer: diff the extracted bodies against the originals line by line;
  this plan's whole risk is an unfaithful lift.
