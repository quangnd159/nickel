# Plan 009: Delete temporary Image.png directories after staging resolves

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- Sources/Nickel/Panel/PanelView.swift`
> On any change to the composer/attachment sections, re-verify the excerpts;
> on a mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

Every image pasted or dropped into the composer is written to a fresh
directory under the system temp dir (`<uuid>/Image.png`) so it has a file to
copy on commit. Nothing ever deletes these: not after a successful commit
(the store *copies*, doesn't move), and not when the user discards the staged
chip. Heavy screenshot use accumulates orphaned temp directories for the life
of the boot session — a small but genuine hole in the app's otherwise careful
attachment lifecycle.

## Current state

All in `Sources/Nickel/Panel/PanelView.swift`:

- `writeTemporaryPNG(_:)` (lines 848-864) creates
  `FileManager.default.temporaryDirectory/<UUID>/Image.png` and returns the
  file URL. Callers: `stagePasteboardAttachments()` (line 731) and
  `loadDroppedAttachment(from:completion:)` (line 829).
- Staged items live in `@State private var pendingAttachments: [StagedAttachment]`
  (line 63). `StagedAttachment.sourceURL` (line 44) points either at a real
  user file (picker/drag of an existing file — must NOT be deleted) or at
  one of these temp PNGs.
- Discard paths that currently leak:
  - Chip remove button (line 675): `pendingAttachments.removeAll { $0.id == staged.id }`
  - Commit (lines 898-903): `commitComposer()` passes `sourceURL`s to
    `store.add(text:attachments:sourceApp:)` — which *copies* each file
    (`NoteStore.copyAttachments`, `NoteStore.swift:114-140`, uses
    `FileManager.copyItem`) — then sets `pendingAttachments = []`.
- Repo convention: file-system failures are logged via `NSLog` and
  swallowed (see `writeTemporaryPNG`'s catch, line 860). Match it.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | all pass            |

## Scope

**In scope**:
- `Sources/Nickel/Panel/PanelView.swift`

**Out of scope**:
- `NoteStore.swift` — the copy semantics stay; do not switch to `moveItem`
  (a move would break the multi-attachment staging of the same source and
  the picker/drag case where `sourceURL` is a user file).
- `StagedAttachment`'s stored properties — derive temp-ness, don't persist it.

## Git workflow

- Branch: `advisor/009-temp-png-cleanup`
- One commit, imperative message (e.g. "Delete staged temp image directories on commit and discard").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a discard helper

In `PanelView` (near `writeTemporaryPNG`), add:

```swift
/// Deletes the throwaway temp directory backing a staged raw-image
/// attachment. Only fires for URLs under the app's temp staging area —
/// picker/drag sources are the user's real files and must survive.
private static func removeTemporaryStagingDirectory(for sourceURL: URL) {
    let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL
    let directory = sourceURL.standardizedFileURL.deletingLastPathComponent()
    guard directory.path.hasPrefix(tempRoot.path + "/") else { return }
    do {
        try FileManager.default.removeItem(at: directory)
    } catch {
        NSLog("PanelView: failed to remove temporary staging directory: \(error)")
    }
}
```

(The prefix guard is the load-bearing safety: it makes deletion of a
non-temp source structurally impossible.)

### Step 2: Call it on every path that drops a staged attachment

1. Chip remove (line 675): before `removeAll`, look up the removed staged
   item and call `Self.removeTemporaryStagingDirectory(for: staged.sourceURL)`.
2. `commitComposer()` (lines 898-903): after the `store.add(text:attachments:sourceApp:)`
   call returns (the copy is synchronous), iterate the just-committed
   `pendingAttachments` and call the helper for each, then clear the array
   as today. Also cover the attachment-less early-return branches only if
   they clear `pendingAttachments` (at the planned-at commit they don't —
   the section-command path at line 888 is guarded by
   `pendingAttachments.isEmpty`, so no cleanup needed there; verify this
   still holds).

**Verify**: `swift build` → exit 0, `swift test` → all pass.

### Step 3: Grep-check coverage

**Verify**: `grep -n "removeTemporaryStagingDirectory" Sources/Nickel/Panel/PanelView.swift`
→ 3 matches (definition + chip remove + commit).

## Test plan

The helper lives in a SwiftUI view, so no direct unit test; correctness rests
on the prefix guard (reviewed) plus a manual check if a GUI session is
available: paste a screenshot into the composer, note the temp dir appears
under `$TMPDIR`, commit the note, confirm the temp dir is gone while the
note's attachment opens fine. Record as untested if headless.

## Done criteria

- [ ] `swift build` exits 0; `swift test` all pass
- [ ] Step 3 grep shows exactly 3 matches
- [ ] The helper contains the temp-root prefix guard
- [ ] `git status` shows only `PanelView.swift` modified (plus plans index)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The composer commit path no longer matches the excerpt (e.g. attachments
  now committed asynchronously) — the "copy is synchronous" assumption would
  be false.
- You find `pendingAttachments` cleared anywhere else (a third leak path
  this plan doesn't list) — add the same call *only* if it's an obvious
  sibling; otherwise report.

## Maintenance notes

- If staging ever moves out of `PanelView` (planned direction: an extractable
  `AttachmentStagingModel`), this helper and its call sites move with it and
  become unit-testable — that's the moment to add real tests.
- Reviewer: confirm no call path can delete a picker/drag source file
  (prefix guard present and tested by inspection).
