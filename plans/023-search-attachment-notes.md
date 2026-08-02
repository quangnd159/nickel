# Plan 023: Make search match attachment filenames so attachment-only notes stay findable

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 83d0b46..HEAD -- Sources/Nickel/Panel/SelectionModel.swift Tests/NickelTests/SelectionModelTests.swift`
> If either file changed since this plan was written, compare the excerpts
> below against the live code; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `83d0b46`, 2026-08-02

## Why this matters

Attachment-only notes (a screenshot pasted with no text) are a first-class
note type — `Note`'s doc comment says so explicitly — but search filters on
`note.text` only. An attachment-only note has empty text, so **any**
non-empty search query hides it: it vanishes from the list, and because
`visibleOrder` derives from the same filter, ⌘A, arrow navigation, and
delete all silently skip it while a filter is active. The repo already has
the canonical text projection for such notes (`PasteboardWriter` substitutes
comma-joined filenames when text is empty); search is the one consumer not
using the idea.

## Current state

SwiftPM, macOS 14+, XCTest.

The filter (`Sources/Nickel/Panel/SelectionModel.swift:103-110`):

```swift
/// Notes matching `searchText` (case-insensitive substring), or all of
/// `store.notes` when the search field is empty. The single source both
/// `PanelView`'s rendering and `visibleOrder` below filter from, so the
/// two can never diverge.
var filteredNotes: [Note] {
    guard !searchText.isEmpty else { return store.notes }
    return store.notes.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
}
```

The note contract (`Sources/Nickel/Store/Note.swift:10-12`):

```swift
/// Files/images attached to this note (Copper-style). A note with
/// attachments and empty text is valid (an attachment-only note).
var attachments: [Attachment]
```

The existing projection precedent (`Sources/Nickel/Support/PasteboardWriter.swift:40-45`):

```swift
private static func line(for note: Note) -> String {
    let filenames = note.attachments.map(\.filename).joined(separator: ", ")
    if note.text.isEmpty { return filenames }
    ...
}
```

Test conventions: `Tests/NickelTests/SelectionModelTests.swift` builds a
real `NoteStore` on a temp directory in `setUp` (lines 10-17) and a
`SelectionModel(store:)` on top. To create a note *with an attachment* in a
test, write a small temp file and call
`store.add(text:attachments:sourceApp:)` (`NoteStore.swift:98`) with a tuple
`(sourceURL:filename:contentType:)`. There is an existing filter test,
`testSelectionOfNoteHiddenByFilterSurvives` — match its style.

Performance context: a prior optimization made filtering single-pass
(commit `295d81b`). Keep the predicate a single pass per note — checking
text first and attachments only on miss is fine; do not add any per-call
index building.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | exit 0, all pass    |

## Scope

**In scope**:
- `Sources/Nickel/Panel/SelectionModel.swift` (only `filteredNotes` and its doc comment)
- `Tests/NickelTests/SelectionModelTests.swift`
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `PasteboardWriter` (its projection stays private; duplicating the
  two-line predicate is simpler than a shared abstraction here).
- `sourceApp` matching — considered and deliberately not included this round.
- `visibleOrder` / grouping code (a separate perf plan touches its callers).

## Git workflow

- Branch: `advisor/023-search-attachment-notes`
- Commit style: short imperative subject, e.g. "Match attachment filenames in note search".
- Do NOT push or open a PR.

## Steps

### Step 1: Extend the predicate

```swift
var filteredNotes: [Note] {
    guard !searchText.isEmpty else { return store.notes }
    return store.notes.filter { note in
        note.text.localizedCaseInsensitiveContains(searchText)
            || note.attachments.contains { $0.filename.localizedCaseInsensitiveContains(searchText) }
    }
}
```

Update the doc comment: "case-insensitive substring over the note's text
and its attachments' filenames".

**Verify**: `swift build` → exit 0; `swift test` → existing filter test passes.

### Step 2: Tests

Add to `SelectionModelTests.swift`:

1. `testSearchMatchesAttachmentOnlyNoteByFilename`: add a text note "alpha"
   and an attachment-only note whose attachment filename is
   "screenshot-beta.png" (create a real temp file for the source). Set
   `selection.searchText = "beta"`. Assert `filteredNotes` contains exactly
   the attachment-only note and `visibleOrder` contains exactly its id.
2. `testSearchStillMatchesTextWhenNoteHasAttachments`: a note with text
   "gamma" *and* an attachment named "other.png"; search "gamma" → matched.
3. `testSearchMissesWhenNeitherTextNorFilenameMatch`: search "zzz" →
   `filteredNotes` empty.

**Verify**: `swift test --filter SelectionModelTests` → all pass.

## Test plan

See step 2 — three tests in `SelectionModelTests.swift`, modeled on the
existing temp-store pattern and the existing filter test.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0; the three new tests pass
- [ ] `filteredNotes` matches attachments (grep for `attachments.contains` in `SelectionModel.swift`)
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- `filteredNotes` doesn't match the excerpt.
- `store.add(text:attachments:sourceApp:)`'s signature has changed
  incompatibly (plan 017 makes it `@discardableResult` returning `[Int]` —
  that is compatible; anything else, stop).

## Maintenance notes

- If a `Note.searchableText` computed property is ever introduced (e.g. to
  add `sourceApp` to search), fold this predicate into it and update
  `PasteboardWriter.line(for:)` to share the filename join.
- Reviewer: confirm the empty-query fast path (`return store.notes`) is
  untouched — it's what keeps the no-search render cheap.
