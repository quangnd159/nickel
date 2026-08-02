# Plan 017: Keep failed attachment copies staged instead of silently destroying them

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 83d0b46..HEAD -- Sources/Nickel/Store/NoteStore.swift Sources/Nickel/Panel/PanelView.swift Tests/NickelTests/NoteStoreTests.swift`
> Plans 015/016 also edit NoteStore.swift (`load`/`init`/`merge` areas) —
> that drift is expected. If `add(text:attachments:sourceApp:)`,
> `copyAttachments`, or `commitComposer` differ from the excerpts below,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S–M
- **Risk**: LOW
- **Depends on**: plans/016-merge-attachment-safety.md (soft — same file; execute in order)
- **Category**: bug
- **Planned at**: commit `83d0b46`, 2026-08-02

## Why this matters

When the composer commits a note with staged attachments, each staged file is
copied into the store's `Attachments/` directory. A failed copy is only
logged — but `commitComposer` then deletes the temp staging directory for
*every* staged item and clears the staging list. For a pasted screenshot
(which exists only in that temp directory), a failed copy destroys the only
copy of the image while the UI reports nothing. After this plan, items that
failed to copy stay staged in the composer, their temp files survive, and the
user sees a toast saying the attach failed.

## Current state

SwiftPM package, macOS 14+, AppKit + SwiftUI, XCTest.

`NoteStore.add(text:attachments:sourceApp:)` (`Sources/Nickel/Store/NoteStore.swift:98-113`):

```swift
func add(text: String, attachments: [(sourceURL: URL, filename: String, contentType: String)], sourceApp: String?) {
    let noteID = UUID()
    let savedAttachments = copyAttachments(attachments, intoNoteDirectoryFor: noteID)

    let note = Note(
        id: noteID,
        text: Self.capped(text),
        listName: activeSection,
        isDone: false,
        createdAt: Date(),
        sourceApp: sourceApp,
        attachments: savedAttachments
    )
    notes.append(note)
    scheduleSave()
}
```

`copyAttachments` (`NoteStore.swift:118-144`) already returns only what
saved, but the caller can't tell *which inputs* failed:

```swift
private func copyAttachments(
    _ inputs: [(sourceURL: URL, filename: String, contentType: String)],
    intoNoteDirectoryFor noteID: UUID
) -> [Attachment] {
    guard !inputs.isEmpty else { return [] }
    let destinationDirectory = attachmentsDirectory.appendingPathComponent(noteID.uuidString, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    } catch {
        NSLog("NoteStore: failed to create attachments directory: \(error)")
        return []
    }
    var saved: [Attachment] = []
    for input in inputs {
        let attachment = Attachment(id: UUID(), filename: input.filename, contentType: input.contentType)
        let destination = destinationDirectory.appendingPathComponent(attachmentFilename(attachment))
        do {
            try FileManager.default.copyItem(at: input.sourceURL, to: destination)
            saved.append(attachment)
        } catch {
            NSLog("NoteStore: failed to copy attachment \"\(input.filename)\": \(error)")
        }
    }
    return saved
}
```

`PanelView.commitComposer` (`Sources/Nickel/Panel/PanelView.swift:899-926`)
destroys staging unconditionally:

```swift
if pendingAttachments.isEmpty {
    store.add(text: text, sourceApp: nil)
} else {
    let attachments = pendingAttachments.map { (sourceURL: $0.sourceURL, filename: $0.filename, contentType: $0.contentType) }
    store.add(text: text, attachments: attachments, sourceApp: nil)
    for staged in pendingAttachments {
        Self.removeTemporaryStagingDirectory(for: staged.sourceURL)
    }
    pendingAttachments = []
}
composerText = ""
```

The toast mechanism to reuse (`PanelView.swift:792-806`) — `showAttachmentToast(count:)`
sets `@State attachmentToast: String?` with a cancellable dismiss work item.
`StagedAttachment` is defined at `PanelView.swift:42`.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | exit 0, all pass    |

## Scope

**In scope**:
- `Sources/Nickel/Store/NoteStore.swift` (only `add(text:attachments:sourceApp:)` and `copyAttachments`)
- `Sources/Nickel/Panel/PanelView.swift` (only `commitComposer` and the toast helper if a message variant is needed)
- `Tests/NickelTests/NoteStoreTests.swift`
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `merge` / `moveAttachmentFiles` (plan 016), `load`/sweep (plan 015).
- The staging *intake* paths (`stagePasteboardAttachments`, `handleComposerDrop`, etc.).
- `FloatingPanel.swift`.

## Git workflow

- Branch: `advisor/017-attachment-copy-failure`
- Commit style: short imperative subject, e.g. "Keep failed attachment copies staged in the composer".
- Do NOT push or open a PR.

## Steps

### Step 1: Report failed input indices from the store

Change `copyAttachments` to also collect failed input indices, and `add` to
return them:

```swift
// copyAttachments returns (saved: [Attachment], failedIndices: [Int])
// - directory-creation failure => (saved: [], failedIndices: Array(inputs.indices))
// - per-file copy failure at position i => i appended to failedIndices

@discardableResult
func add(text: String, attachments: [(sourceURL: URL, filename: String, contentType: String)], sourceApp: String?) -> [Int]
```

`add` builds the note from `saved` exactly as today and returns
`failedIndices`. Indices refer to positions in the `attachments` argument.

**Verify**: `swift build` → exit 0; `swift test` → existing attachment tests pass.

### Step 2: Store tests

In `NoteStoreTests.swift` (temp-directory pattern, lines 9-23):

1. `testAddReportsFailedAttachmentIndices`: stage two inputs — one real temp
   file, one `sourceURL` pointing at a nonexistent path. Call `add`. Assert
   the return is `[1]`, the note has exactly one attachment, and its file
   exists at `store.url(for:in:)`.
2. `testAddAllAttachmentsSucceedReturnsEmpty`: one real file → returns `[]`.

**Verify**: `swift test --filter NoteStoreTests` → all pass.

### Step 3: Composer keeps failures staged

In `commitComposer`, use the returned indices:

```swift
let attachments = pendingAttachments.map { (sourceURL: $0.sourceURL, filename: $0.filename, contentType: $0.contentType) }
let failedIndices = store.add(text: text, attachments: attachments, sourceApp: nil)
let failed = Set(failedIndices)
for (index, staged) in pendingAttachments.enumerated() where !failed.contains(index) {
    Self.removeTemporaryStagingDirectory(for: staged.sourceURL)
}
pendingAttachments = failedIndices.compactMap { pendingAttachments.indices.contains($0) ? pendingAttachments[$0] : nil }
if !failedIndices.isEmpty {
    // Reuse the toast pipeline; add a message-variant helper if needed,
    // matching showAttachmentToast's animation + dismiss pattern exactly.
    showAttachmentFailureToast(count: failedIndices.count) // "Couldn't attach 1 file" / "... N files"
}
composerText = ""
```

Note: today `composerText = ""` runs after the if/else; keep clearing the
text even when attachments failed (the text was saved into the note). The
failed items remain visible as staged chips so the user can retry (Return
again) or remove them.

**Verify**: `swift build` → exit 0; `swift test` → all pass.

## Test plan

Step 2's two store tests are the machine-verifiable core (the failure path
and the happy path). The composer half is SwiftUI `@State` logic with no
existing view-test harness — do not build one; the store tests plus a build
are the gate. Model tests on `NoteStoreTests.swift` style.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0; the two new tests pass
- [ ] `add(text:attachments:sourceApp:)` is `@discardableResult` returning `[Int]`
- [ ] `commitComposer` no longer unconditionally removes all staging dirs
      (grep: the `for staged in pendingAttachments` loop is index-filtered)
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- `commitComposer` or `copyAttachments` don't match the excerpts (beyond
  plans 015/016 drift elsewhere in the file).
- Any other caller of `add(text:attachments:sourceApp:)` exists besides
  `commitComposer` (`grep -rn "attachments:" Sources/ --include="*.swift"`
  first) — if one exists, report it rather than guessing its failure UX.
- Reusing the toast requires restructuring `PanelView` state beyond adding
  one helper function.

## Maintenance notes

- If a "retry attach" affordance is ever added, the failed `StagedAttachment`s
  retained here are exactly the retry inputs.
- Reviewer: check the index math — `pendingAttachments` and the `attachments`
  array passed to `add` must stay parallel (same order, same count) for the
  returned indices to be meaningful.
- Plan 018 adds a persistent save-error surface; this plan's toast is for
  the transient attach failure only. Keep the two messages distinct.
