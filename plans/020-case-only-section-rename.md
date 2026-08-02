# Plan 020: Make case-only section renames work

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 83d0b46..HEAD -- Sources/Nickel/Store/NoteStore.swift Tests/NickelTests/NoteStoreTests.swift`
> Plans 015–019 also edit NoteStore.swift in other functions — that drift is
> expected. If `renameSection(from:to:)` differs from the excerpt below,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/019-bounded-save-debounce.md (soft — same file; execute in order)
- **Category**: bug
- **Planned at**: commit `83d0b46`, 2026-08-02

## Why this matters

Renaming a section only to change its capitalization — "work" → "Work" —
silently does nothing: the header snaps back to the old casing with no
feedback, from every entry point (double-click header, ⇧⌘R, context menu).
The cause: the case-insensitive lookup that detects "rename onto an existing
section" (the merge case) matches *the section being renamed itself*, and
the following guard bails out. The repo's stated bar is Finder-idiom
behavior, and Finder handles case-only folder renames fine.

## Current state

`Sources/Nickel/Store/NoteStore.swift:192-221`:

```swift
func renameSection(from oldName: String, to newName: String) {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != oldName else { return }

    // If an existing (different) section already has this name
    // case-insensitively, merge into it using its existing casing.
    let canonicalName = sections.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed

    guard canonicalName != oldName else { return }

    for index in notes.indices where notes[index].listName == oldName {
        notes[index].listName = canonicalName
    }

    if canonicalName == trimmed {
        // No merge: just rename the section entry in place, preserving order.
        if let sectionIndex = sections.firstIndex(of: oldName) {
            sections[sectionIndex] = canonicalName
        }
    } else {
        // Merge: the destination section already exists, so drop the old one.
        sections.removeAll { $0 == oldName }
    }

    if activeSection == oldName {
        activeSection = canonicalName
    }

    scheduleSave()
}
```

The bug: for `renameSection(from: "work", to: "Work")`, `trimmed` = "Work"
≠ "work" so the first guard passes, but the `canonicalName` lookup finds
"work" (case-insensitive match on the section being renamed), so
`canonicalName == oldName` and the second guard returns.

Existing rename tests: `Tests/NickelTests/NoteStoreTests.swift:121-162`
cover merge, trim, no-op, and empty cases — match their style.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | exit 0, all pass    |

## Scope

**In scope**:
- `Sources/Nickel/Store/NoteStore.swift` (only `renameSection`)
- `Tests/NickelTests/NoteStoreTests.swift`
- `plans/README.md` (status row)

**Out of scope**: everything else, including `createSection` /
`uniqueProvisionalSectionName` (they have their own case-insensitive logic
that is correct as-is) and any UI file.

## Git workflow

- Branch: `advisor/020-case-only-section-rename`
- Commit style: short imperative subject, e.g. "Let a section rename change only its casing".
- Do NOT push or open a PR.

## Steps

### Step 1: Exclude the renamed section from the canonical lookup

```swift
let canonicalName = sections.first { $0 != oldName && $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
```

With that, a case-only rename resolves `canonicalName` to `trimmed` ("Work")
and falls through to the in-place rename branch. The
`guard canonicalName != oldName else { return }` line can now only trigger
when `trimmed == oldName`, which the first guard already rejects — remove
the now-dead guard, and note in the comment above the lookup that the
renamed section itself is excluded so case-only renames fall through to the
in-place branch.

**Verify**: `swift build` → exit 0; `swift test` → all existing rename tests pass.

### Step 2: Tests

Add to `NoteStoreTests.swift`, matching the style at lines 121-162:

1. `testRenameSectionCaseOnlyUpdatesCasing`: create section "work", add a
   note into it, make it active. `renameSection(from: "work", to: "Work")`.
   Assert `sections == ["Work"]` (same position, new casing), the note's
   `listName == "Work"`, and `activeSection == "Work"`.
2. `testRenameSectionCaseOnlyWithWhitespace`: `renameSection(from: "work",
   to: "  Work  ")` → same result (trim still applies).
3. Confirm the merge case still works (existing test should cover renaming
   "beta" to "ALPHA" merging into existing "Alpha" — if no such
   cross-section case-insensitive merge test exists, add one).

**Verify**: `swift test --filter NoteStoreTests` → all pass.

## Test plan

See step 2 — two new tests plus a merge-behavior check, in
`NoteStoreTests.swift`.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0; new tests pass
- [ ] `renameSection` no longer contains `guard canonicalName != oldName`
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- `renameSection` doesn't match the excerpt.
- Any existing rename test fails after step 1 — that would mean the merge
  semantics depended on the removed guard; report which test and how.

## Maintenance notes

- Reviewer: the only behavior change should be case-only renames going
  through; renaming onto a *different* section that matches
  case-insensitively must still merge.
- Sections are matched by exact string in several places
  (`listName == oldName`); this plan doesn't change that model, it only
  fixes the lookup's self-match.
