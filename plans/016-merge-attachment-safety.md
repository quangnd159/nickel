# Plan 016: Stop merge from destroying attachments whose files failed to move

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 83d0b46..HEAD -- Sources/Nickel/Store/NoteStore.swift Tests/NickelTests/NoteStoreTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. (Plan 015 also edits NoteStore.swift
> — its changes are to `load`/`init`/`moveCorruptFileAside`, which don't
> overlap this plan's functions; that drift is expected and fine.)

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/015-load-failure-nondestructive.md (soft — same file; execute 015 first to avoid merge conflicts)
- **Category**: bug
- **Planned at**: commit `83d0b46`, 2026-08-02

## Why this matters

Merging notes (`merge(ids:)`) physically moves each donor note's attachment
files into the survivor's directory, then deletes the donor's directory.
Today a failed `moveItem` is only logged: the survivor still gets the
attachment **record** appended, and the donor directory — still containing
the file that didn't move — is deleted anyway. The bytes are destroyed while
the UI keeps showing an attachment chip that points at a path that will
never exist. After this plan, only attachments whose files actually moved
are appended to the survivor, and a donor directory with unmoved files is
left on disk instead of deleted.

## Current state

All code is in `Sources/Nickel/Store/NoteStore.swift`. SwiftPM package,
macOS 14+, zero dependencies, XCTest.

`merge` (`NoteStore.swift:359-381`):

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

    for donor in donors where !donor.attachments.isEmpty {
        moveAttachmentFiles(of: donor, intoNoteDirectoryFor: first.id)
    }
    notes[firstIndex].attachments += donors.flatMap(\.attachments)

    let idsToRemove = Set(donors.map(\.id))
    notes.removeAll { idsToRemove.contains($0.id) }
    for donor in donors {
        removeAttachmentsDirectory(forNoteID: donor.id)
    }
    scheduleSave()
}
```

`moveAttachmentFiles` (`NoteStore.swift:422-439`) — returns nothing, swallows
per-file errors:

```swift
private func moveAttachmentFiles(of donor: Note, intoNoteDirectoryFor noteID: UUID) {
    let destinationDirectory = attachmentsDirectory.appendingPathComponent(noteID.uuidString, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    } catch {
        NSLog("NoteStore: failed to create attachments directory while merging: \(error)")
        return
    }
    for attachment in donor.attachments {
        let source = url(for: attachment, in: donor)
        let destination = destinationDirectory.appendingPathComponent(attachmentFilename(attachment))
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            NSLog("NoteStore: failed to move attachment \"\(attachment.filename)\" during merge: \(error)")
        }
    }
}
```

Supporting pieces: `url(for:in:)` at `:397-401` derives an attachment's path
from its owning note's id; `attachmentFilename` at `:403-405` is
`"<attachment-id>-<filename>"`; `removeAttachmentsDirectory(forNoteID:)` at
`:407-415`.

Test conventions: `Tests/NickelTests/NoteStoreTests.swift` — temp-directory
`setUp` at lines 9-23; existing merge/attachment tests live in the same file
(search `merge` there and match their style). To create a note with a real
attachment file in tests, write a small temp file and call
`store.add(text:attachments:sourceApp:)` (signature at `NoteStore.swift:98`).

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | exit 0, all pass    |

## Scope

**In scope**:
- `Sources/Nickel/Store/NoteStore.swift` (only `merge` and `moveAttachmentFiles`)
- `Tests/NickelTests/NoteStoreTests.swift`
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `load` / `init` / sweep / backup code — plan 015's territory.
- `copyAttachments` / `add` — plan 017's territory.
- Any UI file.

## Git workflow

- Branch: `advisor/016-merge-attachment-safety`
- Commit style: short imperative subject, e.g. "Keep only moved attachments on the merge survivor".
- Do NOT push or open a PR.

## Steps

### Step 1: Make `moveAttachmentFiles` report what moved

Change its signature to return the attachments whose files actually moved:

```swift
private func moveAttachmentFiles(of donor: Note, intoNoteDirectoryFor noteID: UUID) -> [Attachment]
```

- On directory-creation failure, return `[]` (as the early return does today).
- Append each attachment to a `moved` array only when `moveItem` succeeds.
- Return `moved`.

**Verify**: `swift build` → exit 0 (the unused-result warning at the call
site is expected until step 2).

### Step 2: Use the result in `merge`

Replace the donor-processing block in `merge` so that:

- The survivor's `attachments` gets only the moved attachments (in donor
  order, as today).
- A donor whose attachments all moved (or had none) gets
  `removeAttachmentsDirectory(forNoteID:)` as today.
- A donor with **any** unmoved attachment keeps its directory on disk
  (skip the removal; log with `NSLog` matching the existing message style,
  e.g. `NSLog("NoteStore: leaving donor attachment directory in place; N file(s) failed to move")`).
- Donor **notes** are still removed from `notes` either way — the merge
  itself still happens; only file handling changes.

Target shape:

```swift
var movedByDonor: [UUID: [Attachment]] = [:]
for donor in donors where !donor.attachments.isEmpty {
    movedByDonor[donor.id] = moveAttachmentFiles(of: donor, intoNoteDirectoryFor: first.id)
}
notes[firstIndex].attachments += donors.flatMap { movedByDonor[$0.id] ?? [] }

let idsToRemove = Set(donors.map(\.id))
notes.removeAll { idsToRemove.contains($0.id) }
for donor in donors {
    let moved = movedByDonor[donor.id] ?? []
    if moved.count == donor.attachments.count {
        removeAttachmentsDirectory(forNoteID: donor.id)
    } else {
        NSLog("NoteStore: leaving attachment directory for \(donor.id) in place; \(donor.attachments.count - moved.count) file(s) failed to move")
    }
}
```

**Verify**: `swift test` → all existing merge tests still pass.

### Step 3: Tests

Add to `NoteStoreTests.swift`:

1. `testMergeMovesAttachmentFilesAndRecords` (may already exist in similar
   form — check first; if an equivalent exists, skip): two notes, donor has
   a real attachment file; merge; assert survivor's `attachments` contains
   it, the file exists at `store.url(for:in:)` for the survivor, and the
   donor directory is gone.
2. `testMergeSkipsRecordsForUnmovableAttachments`: create a donor note with
   an attachment whose on-disk file you **delete** before merging (so
   `moveItem` fails with file-not-found). Merge. Assert: the survivor's
   `attachments` does NOT contain the dead attachment; the merge still
   happened (donor note gone, text joined).
3. `testMergeLeavesDonorDirectoryWhenAMoveFails`: donor with two
   attachments — delete one file, keep the other... note that the *kept*
   file will move successfully, so the donor dir keeps only nothing (the
   missing file never existed on disk). To make the directory-retention
   branch observable, instead make the move fail by pre-creating a
   **collision**: create a file at the destination path
   (`Attachments/<survivor-id>/<attachment-id>-<filename>`) before merging.
   Assert the donor's directory still exists and still contains the donor's
   file.

**Verify**: `swift test --filter NoteStoreTests` → all pass.

## Test plan

See step 3 — three tests in `NoteStoreTests.swift`, following the existing
temp-directory pattern. The collision technique in test 3 is the reliable
way to force `moveItem` to throw while the source file genuinely exists.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0; new tests pass
- [ ] `moveAttachmentFiles` returns `[Attachment]` (grep its signature)
- [ ] Merge no longer contains `donors.flatMap(\.attachments)` appended
      unconditionally (`grep -n "flatMap(\\\\.attachments)" Sources/Nickel/Store/NoteStore.swift` → no unconditional append; the moved-only variant is fine)
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- The `merge`/`moveAttachmentFiles` excerpts don't match the live code
  beyond plan-015 drift in *other* functions.
- Forcing a `moveItem` failure in test 3 proves impossible via the collision
  technique (report what `moveItem` actually did — on some filesystems it
  may overwrite; in that case assert the behavior you observed and flag it).
- The fix appears to require changing `Attachment` or the JSON schema.

## Maintenance notes

- A donor directory left in place is orphaned (its note is gone) and will be
  removed by the orphan sweep on a future clean launch (see plan 015). That
  residual loss window is accepted for now; the real fix is a trash-based
  attachment model, deliberately deferred (see the Undo direction finding in
  `plans/README.md`).
- Reviewer: confirm the merged-text behavior is untouched — this plan only
  changes attachment bookkeeping.
