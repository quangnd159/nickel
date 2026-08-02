# Plan 007: Move the debounced note-store save off the main thread

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- Sources/Nickel/Store/NoteStore.swift`
> On any change to the persistence section, re-verify the excerpt; on a
> mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: MED
- **Depends on**: 003-corruption-recovery-tests.md (safety net for the save path)
- **Category**: perf
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

Every debounced save encodes the *entire* store (all notes, pretty-printed
JSON) and writes it atomically — on the main thread. At today's ~8KB store
this is invisible; it scales linearly with note count/size and will surface
as UI hitches exactly when the panel animates the mutation that triggered the
save. Moving encode+write to a serial background queue removes the ceiling
cheaply, while keeping the terminate-time save synchronous.

## Current state

- `Sources/Nickel/Store/NoteStore.swift`, persistence section (lines 458-483):

```swift
private func scheduleSave() {
    saveWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in self?.saveNow() }
    saveWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: workItem)
}

/// Writes the current notes to disk immediately, bypassing the debounce.
/// Safe to call from `applicationWillTerminate`.
func saveNow() {
    saveWorkItem?.cancel()
    saveWorkItem = nil

    do {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let envelope = StoredEnvelope(version: 2, sections: sections, activeSection: activeSection, notes: notes)
        let data = try Self.makeEncoder().encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    } catch {
        NSLog("NoteStore: failed to save notes: \(error)")
    }
}
```

- All store mutations happen on the main thread (SwiftUI actions +
  `AppDelegate` hops to main before `store.add`). `Note` and
  `StoredEnvelope` are value types — snapshotting the envelope on the main
  thread and encoding it elsewhere is race-free.
- `saveNow()` callers: the debounce work item, `applicationWillTerminate` in
  `AppDelegate.swift`, and tests (`NoteStoreTests.testPersistenceRoundTrips`
  constructs a store, calls `saveNow()`, and immediately reloads — the
  synchronous contract must hold).
- Repo convention: `NSLog` for errors, doc comments state threading
  contracts (see the existing `saveNow` comment). Match both.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | all pass            |

## Scope

**In scope**:
- `Sources/Nickel/Store/NoteStore.swift` (persistence section only)

**Out of scope**:
- `AppDelegate.swift` — `applicationWillTerminate` keeps calling `saveNow()`.
- The encoder settings, envelope format, debounce interval, `load(from:)`.

## Git workflow

- Branch: `advisor/007-background-save`
- One commit, imperative message (e.g. "Encode and write saves on a serial background queue").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the serial save queue and split snapshot from write

In `NoteStore`, add:

```swift
private let saveQueue = DispatchQueue(label: "com.nickel.notestore.save", qos: .utility)
```

Add a private helper that does the disk work given an already-snapshotted
envelope (exactly the body of today's `do` block, taking `envelope` as a
parameter). Then:

- `scheduleSave()`'s work item (still debounced on main): snapshot
  `StoredEnvelope(version: 2, sections: sections, activeSection: activeSection, notes: notes)`
  on the main thread, then `saveQueue.async { write(envelope) }`.
- `saveNow()`: keep its public synchronous contract — snapshot the envelope,
  then `saveQueue.sync { write(envelope) }`. The `sync` also fences any
  in-flight async save ahead of it (serial queue), so the last write is
  always the newest snapshot. Keep the existing "Safe to call from
  `applicationWillTerminate`" doc comment and extend it with one line noting
  the queue fencing.

Ordering note (state in a comment): snapshots are taken on the main thread in
mutation order and enqueued on a serial queue, so writes can never reorder.

**Verify**: `swift build` → exit 0.

### Step 2: Run the full suite

`testPersistenceRoundTrips` exercises the synchronous `saveNow()` → reload
path and the corruption tests from Plan 003 exercise `load`; all must pass
unchanged.

**Verify**: `swift test` → all pass.

## Test plan

Existing tests cover the contract (synchronous `saveNow` round-trip,
corruption recovery). Add one new test in `NoteStoreTests.swift`:
`testScheduledSaveEventuallyWritesFile` — mutate the store, then poll (up to
~2s, sleeping 50ms) for `fileURL` to exist and decode to the expected note;
this pins the async path actually writing. Use polling, not a fixed sleep.

## Done criteria

- [ ] `swift build` exits 0; `swift test` all pass including the new async test
- [ ] `saveNow()` remains synchronous (returns only after the write attempt)
- [ ] Envelope snapshot happens on the caller (main) thread; only
      encode+write run on `saveQueue`
- [ ] `git status` shows only `NoteStore.swift` + `NoteStoreTests.swift`
      modified (plus plans index)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The persistence section no longer matches the excerpt.
- You find any store mutation occurring off the main thread (would make the
  snapshot racy) — report; do not add locking on your own.
- The new async test is flaky after two attempts at reasonable poll bounds.

## Maintenance notes

- Any future change that mutates `notes`/`sections` off the main thread
  breaks the snapshot's race-freedom assumption — the doc comment must keep
  saying so.
- Reviewer: check `saveNow()` still cancels the pending debounce work item
  (no double-write after terminate) and that no `self` capture keeps the
  store alive in long queue backlogs (use the snapshot, not `self`, in the
  queued closure).
