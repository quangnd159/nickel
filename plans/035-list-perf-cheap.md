# Plan 035: Cut the two cheap list-scaling costs — index-keyed re-hosting and per-row linear note lookup

> **Executor instructions**: Follow this plan step by step, verifying each
> step. On any STOP condition, stop and report. Update this plan's row in
> `plans/README.md` when done — unless a reviewer told you they maintain the
> index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/Panel/NoteListTable.swift Sources/Nickel/Panel/NoteListRows.swift Sources/Nickel/Panel/NoteRow.swift Sources/Nickel/Panel/LogbookView.swift Sources/Nickel/Store/NoteStore.swift`
> On change, compare excerpts; mismatch = STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

Two independent O(N)-per-N costs make list updates quadratic-ish as notes
grow, both cheap to remove:

1. A cell re-hosts its entire SwiftUI content whenever its ROW INDEX
   changes, but only Logbook day headers actually use the index (for their
   top padding). Inserting one note at the top shifts every index below it,
   so every existing cell rebuilds byte-identical content, throws away its
   settled height signal, and triggers a deferred re-measure — the dominant
   cost of every insert, delete, and drop.
2. Every note row resolves its `Note` by a linear scan of ALL notes (live
   and archived): `store.notes.first { $0.id == noteID }`, per body
   evaluation, per row. A store mutation re-renders every hosted row →
   O(rows × notes).

## Current state

- Re-host key — `Sources/Nickel/Panel/NoteListTable.swift:1116-1121`:

```swift
func configure(content: some View, row: NoteListRow, index: Int, interactive: Bool) {
    host.isInteractive = interactive
    guard configuredRow != row || configuredIndex != index else { return }
    configuredRow = row
    configuredIndex = index
```

- The only index-sensitive content — `NoteListTable.swift:937-939`:

```swift
case .dayHeader(let day):
    LogbookDayHeader(day: day)
        .padding(.top, index == 0 ? 0 : 12)
```

  (`.note` ignores `index`; `.sectionHeader` has a constant `.padding(.top, 12)`;
  `.logbookFooter` constant. Verify by reading `content(for:at:)`,
  `NoteListTable.swift:914-944`.)
- Row model — `Sources/Nickel/Panel/NoteListRows.swift:11-15`:

```swift
enum NoteListRow: Hashable {
    case note(UUID)
    case sectionHeader(String)
    case dayHeader(Date)
    case logbookFooter
}
```

- Linear lookups — `Sources/Nickel/Panel/NoteRow.swift:83` and
  `Sources/Nickel/Panel/LogbookView.swift:146`, both:

```swift
private var note: Note? { store.notes.first { $0.id == noteID } }
```

- `NoteStore` (`Sources/Nickel/Store/NoteStore.swift`) has `@Published
  private(set) var notes` (verify exact declaration) and no `notesByID`
  index today. The repo CLAUDE.md documents "Row content reads its note out
  of the store by id" as a deliberate anti-staleness rule — the CONTRACT
  stays; only the lookup cost changes.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | 377 + any new pass |
| Probe | `NICKEL_UI_PROBE=1 .build/debug/Nickel` | all checks passed |

## Scope

**In scope**:
- `Sources/Nickel/Panel/NoteListRows.swift` (encode first-day-header state)
- `Sources/Nickel/Panel/NoteListTable.swift` (`configure`, `content(for:at:)`,
  `refreshExistingCells` call site)
- `Sources/Nickel/Panel/NoteRow.swift`, `Sources/Nickel/Panel/LogbookView.swift`
  (lookup)
- `Sources/Nickel/Store/NoteStore.swift` (the id index)
- `Tests/NickelTests/NoteListRowsTests.swift` (adjust for the row-model change)

**Out of scope**:
- The update-pipeline short-circuiting and resize coalescing (plan 036).
- Any change to the diffing algorithm or the height flush.

## Git workflow

- Branch: `advisor/035-list-perf-cheap` from `main`
  (`git checkout -b advisor/035-list-perf-cheap main`).

## Steps

### Step 1: Make row content index-free

Change `NoteListRow.dayHeader` to carry its own leading-gap fact:
`case dayHeader(Date, isFirst: Bool)` — set by `NoteListRows.rows(...)`
where day headers are built (first one gets `isFirst: true`). Update
`content(for:at:)` to `.padding(.top, isFirst ? 0 : 12)` and DELETE the
`index` parameter from `content(for:)` entirely (update the measuring call
site in `measureOutstandingRowHeights` too). Then narrow `configure`'s
re-host guard to `guard configuredRow != row else { return }` and delete
`configuredIndex`.

Consequence check: `NoteListDiff` compares `NoteListRow` values — a day
header whose `isFirst` flips (its group became/stopped being first) now
diffs as remove+insert of that one header row. That is correct and cheap.
Update `NoteListRowsTests` expectations accordingly (the enum shape change
will make this compile-driven).

**Verify**: `swift build` → exit 0; `swift test` → all pass (after test
adjustments); `NICKEL_UI_PROBE=1 .build/debug/Nickel` → all checks passed
(Logbook day-header spacing checks especially).

### Step 2: O(1) note lookup

On `NoteStore`, add a maintained index:

```swift
/// O(1) row lookup; rebuilt wherever `notes` is assigned/mutated. The
/// by-id read contract (see CLAUDE.md) is unchanged — only its cost.
private(set) var notesByID: [UUID: Note] = [:]
```

Find every place `notes` changes (didSet on the property if it exists, or
each mutation + load site — `grep -n "notes =" Sources/Nickel/Store/NoteStore.swift`
and `notes[index]`/`notes.append`/`notes.removeAll` sites). SIMPLEST
CORRECT OPTION: a `didSet` on `notes` rebuilding the dictionary — O(N) per
mutation, which is fine (mutations are user-actions, not per-row), and
immune to a missed site. Use `Dictionary(notes.map { ($0.id, $0) },
uniquingKeysWith: { first, _ in first })` — duplicate-tolerant, matching
the existing defensive pattern in `PanelActions.notes(for:)`.
Then change both row lookups to `store.notesByID[noteID]`.

Check `@Published notes`: `didSet` on a `@Published` property fires on
every assignment — verify with a quick test that `notesByID` is in sync
after `add`/`delete` (Step 3).

**Verify**: `swift build` → exit 0.

### Step 3: Tests

In `NoteStoreTests.swift` add: after `add`, `delete`, `move`, `merge`,
`markDone` — `store.notesByID[id]` matches `store.notes.first(where:)` for
a sampled id, and counts agree. One parameterized test is enough.

**Verify**: `swift test` → all pass.

## Test plan

As steps; the probe guards the visual behavior (day-header spacing, heights
after drop).

## Done criteria

- [ ] `swift build` exit 0, no warnings
- [ ] `swift test` all pass; `notesByID` sync test present
- [ ] Probe passes
- [ ] `grep -n "configuredIndex" Sources/` → no matches
- [ ] `grep -n "notes.first { \$0.id == noteID }" Sources/Nickel/Panel/` → no matches
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails.
- `content(for:at:)`'s index is used anywhere else you find that this plan
  didn't list — report before changing it.
- `didSet` on the `@Published notes` property doesn't fire for some
  mutation path (verify via the Step 3 test) — report; do not hand-sprinkle
  rebuilds without saying so.

## Maintenance notes

- New `NoteListRow` cases must carry their own display facts rather than
  reading the row index.
- Reviewer: check no call site still passes an index into `content`.
