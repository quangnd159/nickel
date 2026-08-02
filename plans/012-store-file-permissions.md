# Plan 012: Restrict notes.json and the store directory to owner-only access

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- Sources/Nickel/Store/NoteStore.swift Tests/NickelTests/`
> On changes to the persistence section, re-verify the excerpts; on a
> mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 007-background-save.md (touches the same save function; land 007 first to avoid conflicts)
- **Category**: security
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

Nickel's whole purpose is capturing selected text from arbitrary apps — which
can include passwords, tokens, or private messages the user briefly selected.
That content persists indefinitely in cleartext, and the store is currently
written world-readable (verified on a live install: `notes.json` is
`rw-r--r--`, the `Nickel/` directory `rwxr-xr-x`). Owner-only permissions are
the cheap, standard hardening; encryption was considered and rejected as
disproportionate for a local single-user scratchpad.

## Current state

- `Sources/Nickel/Store/NoteStore.swift`, `saveNow()` (lines 469-483 at the
  planned-at commit; if Plan 007 landed, the same logic lives in the private
  write helper on the save queue — apply the change there):
  - Creates the directory via
    `FileManager.default.createDirectory(at:withIntermediateDirectories:)`
    with no attributes, then `data.write(to: fileURL, options: .atomic)`
    with no permission tightening. `.atomic` writes a temp file and renames,
    so permissions must be (re)applied after the write — they don't stick
    from a previous chmod of the destination.
- Attachments live under the same parent directory
  (`NoteStore.attachmentsDirectory`, used by `copyAttachments`,
  lines 114-140) — securing the *store directory* at `0o700` covers them via
  directory traversal denial, so per-file attachment chmod is unnecessary.
- Test exemplar: `Tests/NickelTests/NoteStoreTests.swift` (temp-dir fixture).

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | all pass            |

## Scope

**In scope**:
- `Sources/Nickel/Store/NoteStore.swift` (directory creation + post-write
  permission application)
- `Tests/NickelTests/NoteStoreTests.swift` (one new test)

**Out of scope**:
- Encryption, Keychain, or any at-rest crypto — rejected during audit.
- Attachment per-file permissions (covered by the directory, above).
- `moveCorruptFileAside` — the `.bak` inherits the original file's
  permissions via `moveItem`; after this plan new saves are 0600 so the
  corpse will be too. No extra handling.

## Git workflow

- Branch: `advisor/012-store-file-permissions`
- One commit, imperative message (e.g. "Write the note store owner-only").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Apply permissions at directory creation and after each write

In the save path (wherever `createDirectory` + `data.write` live after
Plan 007):

1. Pass attributes at creation:
   `createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])`.
   Note: attributes only apply to *newly created* directories, so also…
2. After a successful `data.write(to:options:.atomic)`, apply both
   (idempotent, and migrates existing installs on their next save):

```swift
try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
```

Use `try?` with no logging: a chmod failure must never fail the save (the
data mattering more than the mode), and the repo's `NSLog`-on-error style is
reserved for save failures themselves. State that in a one-line comment.

**Verify**: `swift build` → exit 0.

### Step 2: Add a permissions test

In `NoteStoreTests.swift`:
`testSaveAppliesOwnerOnlyPermissions` — `store.add(...)`, `store.saveNow()`,
then read `FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]`
and assert `(perms as? NSNumber)?.uint16Value == 0o600`; same for the parent
directory and `0o700`.

**Verify**: `swift test` → all pass including the new test.

## Test plan

Step 2's test is the machine check. Manually (optional, GUI install):
`ls -l ~/Library/Application\ Support/Nickel/` after the next save shows
`-rw-------` / `drwx------`.

## Done criteria

- [ ] `swift build` exits 0; `swift test` all pass incl.
      `testSaveAppliesOwnerOnlyPermissions`
- [ ] Both the directory-creation attributes and post-write `setAttributes`
      calls exist
- [ ] `git status` shows only the two in-scope files modified (plus plans index)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The save path has been restructured beyond Plan 007's shape and you can't
  locate a single write site — report rather than sprinkling chmods.
- The permissions test fails on the temp-dir fixture (some CI filesystems
  ignore chmod) — report with the observed mode; don't weaken the assertion
  blindly.

## Maintenance notes

- Any new file the store writes (exports, additional backups) should get the
  same treatment; the post-write `setAttributes` pattern is the exemplar.
- Reviewer: confirm the chmod is *after* the atomic write (rename replaces
  the inode, discarding prior modes).
