# Plan 018: Surface note-save failures in the panel instead of NSLog-only

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 83d0b46..HEAD -- Sources/Nickel/Store/NoteStore.swift Sources/Nickel/Panel/PanelView.swift Tests/NickelTests/NoteStoreTests.swift`
> Plans 015–017 also edit these files (load/sweep, merge, attachment-copy
> areas) — that drift is expected. If `write(_:)` or `saveNow()` differ from
> the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/017-attachment-copy-failure.md (soft — same files; execute in order)
- **Category**: bug
- **Planned at**: commit `83d0b46`, 2026-08-02

## Why this matters

The one job of a note-capture app is not losing notes. Today, if writing
`notes.json` fails (full disk, permissions, vanished directory), the error
goes to `NSLog` and nowhere else: the note appears in the panel, the JSON on
disk is stale, and the user finds out at next launch when the note is gone.
After this plan, a failed save shows a persistent, dismiss-proof warning
banner in the panel until a save succeeds again.

## Current state

SwiftPM package, macOS 14+, AppKit + SwiftUI, XCTest.
`NoteStore` is an `ObservableObject` used via `@EnvironmentObject` in
`PanelView`. Saves are debounced onto a serial background queue.

`write(_:)` — only ever called on `saveQueue` (`Sources/Nickel/Store/NoteStore.swift:493-512`):

```swift
private func write(_ envelope: StoredEnvelope) {
    do {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let data = try Self.makeEncoder().encode(envelope)
        try data.write(to: fileURL, options: .atomic)

        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
        NSLog("NoteStore: failed to save notes: \(error)")
    }
}
```

`saveNow()` (`NoteStore.swift:483-491`) snapshots and calls
`saveQueue.sync { self.write(envelope) }`. The debounced path is
`scheduleSave()` (`NoteStore.swift:464-476`), which async-dispatches `write`
onto `saveQueue`.

`PanelView` already has a small transient toast
(`attachmentToastView(_:)` at `PanelView.swift:638`, displayed at
`PanelView.swift:603-604` inside the main VStack when
`@State attachmentToast` is non-nil). The save-error banner should be a
separate, simpler element: driven by store state, not `@State`, and not
auto-dismissing.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | exit 0, all pass    |

## Scope

**In scope**:
- `Sources/Nickel/Store/NoteStore.swift` (add published error state; touch only `write`)
- `Sources/Nickel/Panel/PanelView.swift` (banner view + placement)
- `Tests/NickelTests/NoteStoreTests.swift`
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `scheduleSave` timing (plan 019's territory), `load`/sweep (015),
  `merge` (016), attachment copying (017).
- `NSLog` sites other than the `write` catch (they stay as-is this round).
- Alert dialogs — no modal UI; a banner only.

## Git workflow

- Branch: `advisor/018-surface-save-failures`
- Commit style: short imperative subject, e.g. "Show a banner while note saves are failing".
- Do NOT push or open a PR.

## Steps

### Step 1: Published save-error state on NoteStore

Add to `NoteStore`:

```swift
/// Non-nil while the most recent notes.json write failed; cleared by the
/// next successful write. Set on the main thread (write runs on saveQueue).
@Published private(set) var saveError: String?
```

In `write(_:)`'s `do` block append, after the permission re-application:

```swift
if saveError != nil {
    DispatchQueue.main.async { self.saveError = nil }
}
```

and in the `catch`, alongside the existing `NSLog`:

```swift
DispatchQueue.main.async { self.saveError = error.localizedDescription }
```

Note: reading `saveError` from `saveQueue` in that `if` is a benign race
(worst case one redundant main-queue hop); if you prefer, unconditionally
dispatch the clear. Either is acceptable.

**Verify**: `swift build` → exit 0.

### Step 2: Store tests

In `NoteStoreTests.swift` (temp-directory `setUp` pattern, lines 9-23):

1. `testFailedWriteSetsSaveError`: construct a store, then make the store
   file unwritable — replace `fileURL`'s parent directory with a **file** is
   messy; instead point a fresh store at a path whose parent directory is
   read-only: create `tempDirectory/readonly/`, `chmod` it `0o500` via
   `FileManager.setAttributes([.posixPermissions: 0o500], ...)`, then
   `NoteStore(fileURL: .../readonly/sub/notes.json)` — `createDirectory`
   inside `write` will throw. Call `store.add(text:sourceApp:)` then
   `store.saveNow()`. Drain the main queue (e.g.
   `let exp = expectation(...); DispatchQueue.main.async { exp.fulfill() };
   wait(...)`) and assert `store.saveError != nil`.
2. `testSuccessfulWriteClearsSaveError`: continue from the failure state —
   restore the directory to `0o700`, call `saveNow()` again, drain main,
   assert `saveError == nil`.
3. In `tearDown` or the test itself, restore permissions before removing the
   temp directory so cleanup doesn't fail.

**Verify**: `swift test --filter NoteStoreTests` → all pass.

### Step 3: Banner in PanelView

In `PanelView`'s main layout, directly above where the attachment toast is
shown (`PanelView.swift:603-604`), add:

```swift
if let saveError = store.saveError {
    saveErrorBanner(saveError)
}
```

with a private helper view: a compact horizontal banner —
`Image(systemName: "exclamationmark.triangle.fill")`, text
`"Couldn't save notes: \(message)"`, `.font(.callout)`, warning-tinted
background (`Color.yellow.opacity(...)` or `.orange`), rounded rect,
horizontal padding matching the toast's. No dismiss button — it clears
itself when a save succeeds. Match the visual language of
`attachmentToastView(_:)` at `PanelView.swift:638` (read it and mirror its
padding/corner styling).

**Verify**: `swift build` → exit 0; `swift test` → all pass.

## Test plan

Step 2's two tests are the gate: error set on failed write, cleared on
success. The banner itself is presentation-only SwiftUI; the build is its
gate (no view-test harness exists in this repo — do not add one).

## Done criteria

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0; both new tests pass
- [ ] `grep -n "saveError" Sources/Nickel/Store/NoteStore.swift` shows the
      `@Published` property, one set in `catch`, one clear on success
- [ ] `grep -n "saveError" Sources/Nickel/Panel/PanelView.swift` shows the
      banner conditional
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- `write(_:)`/`saveNow()` don't match the excerpts (beyond expected
  015–017 drift elsewhere).
- The read-only-directory technique fails to make `write` throw on this
  filesystem (report what happened; do not switch to mocking FileManager).
- Publishing from the background thread proves unavoidable (all mutations
  of `saveError` must go through `DispatchQueue.main.async` — if some code
  path can't, report it).

## Maintenance notes

- The debounced save can fire repeatedly while the disk stays full; the
  banner design (persistent state, not per-event toast) is what prevents an
  alert storm. Keep it that way if this is ever extended.
- Follow-up deliberately out of scope: surfacing the other ~14 NSLog error
  sites (attachment move/remove failures). If those get UI later, they
  should reuse this `saveError`-style published state, not ad-hoc alerts.
- Reviewer: check that `saveError` writes happen only on the main queue
  (`@Published` on an `ObservableObject` consumed by SwiftUI).
