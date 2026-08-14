# Plan 030: Merge notes in their visible order, not creation order

> **Executor instructions**: Follow this plan step by step, verifying each
> step. On any STOP condition, stop and report. Update this plan's row in
> `plans/README.md` when done — unless a reviewer told you they maintain the
> index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/Store/NoteStore.swift Tests/NickelTests/NoteStoreTests.swift`
> On change, compare excerpts; mismatch = STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

Display order in Nickel is the order of the `notes` array — that became
user-controlled when drag-to-reorder landed (`move(ids:toSection:before:)`
repositions notes in the array). `merge(ids:)` still joins text sorted by
`createdAt`, which was identical to display order before reordering existed
but can now diverge. Result: a user drags notes into a deliberate order,
selects them, merges — and the merged note's paragraphs come out in a
different order than what was on screen. The fix joins in array (visible)
order. The surviving note stays the earliest-created one, because its id
anchors the on-disk attachments directory and its array position.

## Current state

- `Sources/Nickel/Store/NoteStore.swift:559-587` (excerpt of the head):

```swift
func merge(ids: Set<UUID>) {
    guard ids.count > 1 else { return }
    let targets = notes.filter { ids.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
    guard let first = targets.first, let firstIndex = notes.firstIndex(where: { $0.id == first.id }) else {
        return
    }
    let donors = targets.dropFirst()

    let mergedText = targets.map(\.text).joined(separator: "\n\n")
    notes[firstIndex].text = mergedText
    ...
```

  Note the THREE distinct roles `targets`'s order currently plays:
  1. text-join order (`mergedText`),
  2. survivor identity (`targets.first` = earliest created),
  3. attachment append order (`donors.flatMap` later in the function).
- The reorder API that made array order user-controlled:
  `NoteStore.move(ids:toSection:before:)` around `NoteStore.swift:270-303`.
- `PanelActions.merge()` (`Sources/Nickel/Panel/PanelActions.swift:129-138`)
  calls `store.merge(ids:)` and then selects the survivor via
  `selectedNotes.min(by: { $0.createdAt < $1.createdAt })?.id` — read it
  before starting; it duplicates the "earliest created survives" rule and
  must keep matching the store's survivor choice.
- Test conventions: `Tests/NickelTests/NoteStoreTests.swift` builds stores
  via `NICKEL_STORE_PATH`-style fixtures / in-memory helpers — find the
  existing `merge` tests there (`grep -n "merge" Tests/NickelTests/NoteStoreTests.swift`)
  and follow their structure.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | 377 + new pass |

## Scope

**In scope**:
- `Sources/Nickel/Store/NoteStore.swift` (`merge(ids:)` only)
- `Tests/NickelTests/NoteStoreTests.swift`

**Out of scope**:
- `PanelActions.merge()` — its survivor-selection rule stays valid because
  the survivor rule doesn't change. Do not edit it.
- `move(ids:toSection:before:)`, attachment relocation helpers.
- Any change to the `"\n\n"` separator.

## Git workflow

- Branch: `advisor/030-merge-visible-order` from `main`
  (`git checkout -b advisor/030-merge-visible-order main`).

## Steps

### Step 1: Split join order from survivor identity

In `merge(ids:)`:

```swift
// Visible order: the notes array IS the display order (drag reorder edits
// it), so the merged text must read top-to-bottom as the user saw it.
let inVisibleOrder = notes.filter { ids.contains($0.id) }
// The earliest-created note survives: its id anchors the on-disk
// attachments directory, so keeping it avoids relocating the survivor's
// own files.
guard let first = inVisibleOrder.min(by: { $0.createdAt < $1.createdAt }), ... 
let donors = inVisibleOrder.filter { $0.id != first.id }
let mergedText = inVisibleOrder.map(\.text).joined(separator: "\n\n")
```

Attachment append order follows `donors` (visible order) — acceptable and
now consistent with the text. Keep everything else identical.

**Verify**: `swift build` → exit 0.

### Step 2: Tests

Add to `NoteStoreTests.swift` (following the existing merge tests' style):

1. Reorder three notes so array order ≠ creation order (use
   `move(ids:toSection:before:)` or construct the array directly the way
   fixtures do), merge them, assert `mergedText` follows the ARRAY order.
2. Assert the survivor is still the earliest-created note (its id remains,
   others gone).
3. Assert donor attachments are appended in visible order (if an existing
   attachment-merge test exists, extend it; otherwise cover order via
   two donors with one attachment each).

**Verify**: `swift test` → all pass, count 377 + new.

## Test plan

As Step 2. Existing merge tests must keep passing unmodified unless one of
them explicitly asserts createdAt-join-order — if so, update that assertion
to array order and note it in the report.

## Done criteria

- [ ] `swift build` exit 0, no warnings
- [ ] `swift test` all pass, incl. new order tests
- [ ] `grep -n "sorted { \$0.createdAt" Sources/Nickel/Store/NoteStore.swift`
      shows no hit inside `merge(ids:)`
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails.
- An existing test encodes the OLD join order as intended behavior with a
  comment saying so — that would mean the order was a decided tradeoff;
  stop and report instead of flipping it.
- `PanelActions.merge()`'s survivor rule turns out to disagree with the
  store's after your change (it must not — you didn't change the rule).

## Maintenance notes

- If merge ever becomes order-configurable, both the store and
  `PanelActions.merge()`'s post-merge selection must change together.
- Reviewer: confirm the survivor's `firstIndex` lookup still uses the
  survivor's id, not `inVisibleOrder.first`.
