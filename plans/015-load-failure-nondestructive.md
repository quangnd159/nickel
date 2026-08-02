# Plan 015: Make store load failures non-destructive (orphan sweep + corrupt backup)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 83d0b46..HEAD -- Sources/Nickel/Store/NoteStore.swift Tests/NickelTests/NoteStoreTests.swift CLAUDE.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `83d0b46`, 2026-08-02

## Why this matters

Nickel stores notes in one JSON file and attachment files under
`Attachments/<note-id>/`. Today, if that JSON file is unreadable or fails to
decode at launch, `load` returns an **empty** note list — and the
orphan-attachment sweep that runs right after init then deletes **every**
attachment directory, because no note "exists" anymore. One transient read
failure or one undecodable byte permanently destroys all attached images.
Worse, the corrupt-file backup always uses the same name (`notes.json.bak`)
and deletes the previous backup first, so a second failure destroys the only
surviving copy of the notes too. This plan makes both paths non-destructive
and pins the behavior with tests.

## Current state

All code is in `Sources/Nickel/Store/NoteStore.swift`. Nickel is a Swift
Package (SwiftPM), macOS 14+, zero external dependencies. Tests are XCTest in
`Tests/NickelTests/`.

`init` loads, then sweeps (`NoteStore.swift:40-52`):

```swift
init(fileURL: URL? = nil) {
    let envOverride = ProcessInfo.processInfo.environment["NICKEL_STORE_PATH"].map { URL(fileURLWithPath: $0) }
    self.fileURL = fileURL ?? envOverride ?? Self.defaultFileURL()

    let loaded = Self.load(from: self.fileURL)
    self.notes = loaded.notes
    self.sections = loaded.sections
    self.activeSection = loaded.activeSection

    sweepOrphanedAttachmentDirectories()
}
```

`load` returns empty on every failure path (`NoteStore.swift:530-559`):

```swift
private static func load(from url: URL) -> Loaded {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return Loaded(notes: [], sections: [], activeSection: nil)
    }
    guard let data = try? Data(contentsOf: url) else {
        NSLog("NoteStore: notes file could not be read, moving aside")
        moveCorruptFileAside(url)
        return Loaded(notes: [], sections: [], activeSection: nil)
    }
    let decoder = makeDecoder()
    if let envelope = try? decoder.decode(StoredEnvelope.self, from: data) {
        return repaired(notes: envelope.notes, sections: envelope.sections, activeSection: envelope.activeSection)
    }
    if let legacyNotes = try? decoder.decode([Note].self, from: data) {
        let sections = distinctListNames(in: legacyNotes)
        return repaired(notes: legacyNotes, sections: sections, activeSection: nil)
    }
    NSLog("NoteStore: notes file is corrupt, moving aside")
    moveCorruptFileAside(url)
    return Loaded(notes: [], sections: [], activeSection: nil)
}
```

`Loaded` is a private struct just above `load` (`NoteStore.swift:524-528`):

```swift
private struct Loaded {
    var notes: [Note]
    var sections: [String]
    var activeSection: String?
}
```

The sweep deletes every attachment dir not owned by a loaded note
(`NoteStore.swift:445-460`):

```swift
private func sweepOrphanedAttachmentDirectories() {
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(
        at: attachmentsDirectory,
        includingPropertiesForKeys: nil
    ) else { return }

    let knownNoteIDs = Set(notes.map { $0.id.uuidString })
    for entry in entries where !knownNoteIDs.contains(entry.lastPathComponent) {
        do {
            try fileManager.removeItem(at: entry)
        } catch { ... }
    }
}
```

The backup overwrites its predecessor (`NoteStore.swift:588-599`):

```swift
private static func moveCorruptFileAside(_ url: URL) {
    let backupURL = url.deletingLastPathComponent().appendingPathComponent("notes.json.bak")
    let fileManager = FileManager.default
    do {
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.moveItem(at: url, to: backupURL)
    } catch { ... }
}
```

`attachmentsDirectory` is `fileURL`'s parent + `Attachments/`
(`NoteStore.swift:389-391`). Test convention: `NoteStoreTests.swift:9-23`
creates a temp directory + `notes.json` path in `setUp` and constructs
`NoteStore(fileURL:)` directly — model all new tests on that file's style
(plain XCTest, one behavior per test, descriptive `testXxx` names).

`CLAUDE.md` (repo root) currently says the suite has "26 tests"; it has 79+.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | exit 0, all pass    |

Do NOT run `./scripts/build-app.sh` (repo rule: only on explicit user request).

## Scope

**In scope** (the only files you should modify):
- `Sources/Nickel/Store/NoteStore.swift`
- `Tests/NickelTests/NoteStoreTests.swift`
- `CLAUDE.md` (one-line doc fix, step 5)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `Sources/Nickel/Panel/**` — UI is unaffected.
- `moveAttachmentFiles` / `merge` — a separate plan (016) covers merge safety.
- Any change to the on-disk JSON format or `StoredEnvelope`.

## Git workflow

- Branch: `advisor/015-load-failure-nondestructive`
- Commit style: short imperative subject, e.g. "Skip the orphan sweep when the store failed to load" (matches `git log`: "Write the note store owner-only").
- Do NOT push or open a PR.

## Steps

### Step 1: Characterization tests for the current sweep (they should pass now)

In `Tests/NickelTests/NoteStoreTests.swift`, add:

1. `testSweepRemovesOrphanedAttachmentDirectoryOnCleanLoad` — write a valid
   v2 store file containing one note (easiest: create a store, `store.add`,
   call `store.saveNow()`, note the note's id). Create
   `Attachments/<that-note-id>/` and `Attachments/<random-UUID>/` under the
   temp directory (each containing a dummy file). Construct a **new**
   `NoteStore(fileURL:)` on the same path. Assert the random-UUID directory
   is gone and the note's directory still exists.

**Verify**: `swift test --filter NoteStoreTests` → all pass.

### Step 2: Gate the sweep on a clean load

- Add `var loadedCleanly: Bool = true` to the private `Loaded` struct.
- In `load`, set `loadedCleanly: false` in the two failure returns (the
  `Data(contentsOf:)` guard and the final corrupt fallthrough). The
  file-absent return and both successful decodes stay `true`.
- In `init`, capture the flag and only sweep when clean:

```swift
if loaded.loadedCleanly {
    sweepOrphanedAttachmentDirectories()
}
```

- Add test `testSweepSkippedWhenStoreFileIsCorrupt`: write garbage bytes
  (e.g. `Data("not json".utf8)`) to `notes.json`, create an
  `Attachments/<random-UUID>/` directory with a dummy file, construct
  `NoteStore(fileURL:)`, assert the attachment directory **still exists**
  and `store.notes.isEmpty`.

**Verify**: `swift test --filter NoteStoreTests` → all pass, including both new tests.

### Step 3: Unique corrupt-backup names

Change `moveCorruptFileAside` to never delete an existing backup: name the
backup `notes-corrupt-<timestamp>.json` where `<timestamp>` is
filesystem-safe (e.g. `ISO8601DateFormatter` output with `:` replaced by
`-`, or a `yyyyMMdd-HHmmss` `DateFormatter`). If a file with that exact name
somehow exists, append a numeric suffix rather than removing anything.
Delete the now-unused "remove existing backup" branch.

Check for existing tests that reference the old name before changing:
`grep -n "notes.json.bak\|\.bak" Tests/NickelTests/NoteStoreTests.swift` —
update any matches to look for a file matching `notes-corrupt-*.json`
instead (assert via `FileManager.contentsOfDirectory` prefix match).

**Verify**: `swift test` → all pass.

### Step 4: Test backup uniqueness

Add `testSecondCorruptLoadDoesNotDestroyFirstBackup`: write garbage to
`notes.json`, construct a store (backup 1 created); write different garbage
to `notes.json` again, construct another store. Assert the temp directory
contains **two** distinct `notes-corrupt-*.json` files whose contents are the
two garbage payloads. (If both loads can land in the same formatter second,
the suffix logic from step 3 must keep them distinct.)

**Verify**: `swift test --filter NoteStoreTests` → all pass.

### Step 5: Fix the stale test count in CLAUDE.md

In `CLAUDE.md`, the Test row of the Commands table says "26 tests". Replace
the count with wording that can't go stale: "XCTest, `Tests/NickelTests/`,
runs in seconds".

**Verify**: `grep -n "26 tests" CLAUDE.md` → no matches.

## Test plan

Covered by steps 1, 2, 4 — three new tests in `NoteStoreTests.swift`,
modeled on the existing `setUp`/`tearDown` temp-directory pattern
(`NoteStoreTests.swift:9-23`). Cases: sweep removes true orphans on clean
load; sweep skipped on corrupt load; corrupt backups never overwrite each
other.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0; the three new tests exist and pass
- [ ] `grep -n "notes.json.bak" Sources/Nickel/Store/NoteStore.swift` → no matches
- [ ] `grep -n "26 tests" CLAUDE.md` → no matches
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts above don't match the live code (drift).
- Existing corruption-recovery tests fail after step 3 for a reason other
  than the backup filename change.
- You find `sweepOrphanedAttachmentDirectories` called from anywhere besides
  `init` (grep first) — the gate design assumes init is the only caller.
- A step's verification fails twice after a reasonable fix attempt.

## Maintenance notes

- Plan 016 (merge attachment safety) leaves failed-to-move donor files on
  disk for the sweep to handle; the clean-load gate here is what makes that
  safe-ish. If a "trash instead of delete" attachment model ever lands
  (undo support), the sweep should move directories there instead of
  `removeItem`.
- Reviewer: check that a fresh install (no notes.json at all) still sweeps —
  the file-absent path is deliberately `loadedCleanly: true`.
- Corrupt backups now accumulate; that's intentional (bounded by how often
  corruption happens, i.e. ~never). A retention cap was considered and
  skipped as machinery.
