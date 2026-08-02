# Plan 019: Bound how long the save debounce can defer a write

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 83d0b46..HEAD -- Sources/Nickel/Store/NoteStore.swift Tests/NickelTests/NoteStoreTests.swift`
> Plans 015–018 also edit NoteStore.swift (load/sweep, merge, attachments,
> write-error surfacing) — that drift is expected. If `scheduleSave()`
> differs from the excerpt below beyond plan 018's error-state lines, treat
> it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/018-surface-save-failures.md (soft — same file; execute in order)
- **Category**: bug
- **Planned at**: commit `83d0b46`, 2026-08-02

## Why this matters

Every store mutation cancels the pending debounced save and reschedules it
0.5s out, with no ceiling. A user who keeps mutating faster than every 0.5s
(holding ⌫ over a selection, typing in an inline editor, arrow-cycling
sections) can go arbitrarily long with nothing written to disk; `saveNow()`
runs only from `applicationWillTerminate`, which macOS does not deliver on a
crash, force-quit, or power loss. A crash then loses the whole editing
streak, not the advertised half-second. This plan adds a deferral ceiling:
no matter how fast mutations arrive, a write lands within ~3 seconds of the
first coalesced mutation.

## Current state

`Sources/Nickel/Store/NoteStore.swift`. SwiftPM, macOS 14+, XCTest.

The debounce constant (`NoteStore.swift:21`):

```swift
private let saveDebounceInterval: TimeInterval = 0.5
```

`scheduleSave()` (`NoteStore.swift:464-476`):

```swift
private func scheduleSave() {
    saveWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
        guard let self else { return }
        let envelope = StoredEnvelope(version: 2, sections: self.sections, activeSection: self.activeSection, notes: self.notes)
        self.saveWorkItem = nil
        self.saveQueue.async {
            self.write(envelope)
        }
    }
    saveWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: workItem)
}
```

All mutations (`add`, `update`, `toggleDone`, `delete`, `move`,
`renameSection`, `merge`, `clearDone`, section ops) call `scheduleSave()`.
`scheduleSave` is called on the main thread (all mutations are UI-driven).

Existing timing-sensitive test pattern to follow: `NoteStoreTests.swift`
around line 309 polls for a condition with a deadline rather than sleeping a
fixed interval — match that pattern for any wall-clock assertion.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | exit 0, all pass    |

## Scope

**In scope**:
- `Sources/Nickel/Store/NoteStore.swift` (only `scheduleSave`, the two
  interval constants, one new timestamp property, and one new pure helper)
- `Tests/NickelTests/NoteStoreTests.swift`
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `write(_:)`, `saveNow()`, `load`, sweep, merge, attachments.
- The `saveQueue` serial-ordering design.
- Any UI file.

## Git workflow

- Branch: `advisor/019-bounded-save-debounce`
- Commit style: short imperative subject, e.g. "Cap how long coalesced saves can be deferred".
- Do NOT push or open a PR.

## Steps

### Step 1: Pure delay helper + constants

Add alongside `saveDebounceInterval`:

```swift
private let maxSaveDeferral: TimeInterval = 3.0
/// When the first not-yet-written mutation of the current coalescing burst
/// happened; nil when no save is pending.
private var firstPendingSaveAt: Date?
```

Add an internal (not private — tests need it) pure helper:

```swift
/// The delay the next debounced save should use: the normal debounce
/// interval, shortened so the write lands no later than `maxDeferral`
/// after `firstPendingAt`. Never negative.
static func nextSaveDelay(firstPendingAt: Date?, now: Date, debounce: TimeInterval, maxDeferral: TimeInterval) -> TimeInterval {
    guard let firstPendingAt else { return debounce }
    let ceilingRemaining = maxDeferral - now.timeIntervalSince(firstPendingAt)
    return max(0, min(debounce, ceilingRemaining))
}
```

**Verify**: `swift build` → exit 0.

### Step 2: Use it in scheduleSave

```swift
private func scheduleSave() {
    saveWorkItem?.cancel()
    let now = Date()
    if firstPendingSaveAt == nil { firstPendingSaveAt = now }
    let delay = Self.nextSaveDelay(firstPendingAt: firstPendingSaveAt, now: now, debounce: saveDebounceInterval, maxDeferral: maxSaveDeferral)
    let workItem = DispatchWorkItem { [weak self] in
        guard let self else { return }
        let envelope = StoredEnvelope(version: 2, sections: self.sections, activeSection: self.activeSection, notes: self.notes)
        self.saveWorkItem = nil
        self.firstPendingSaveAt = nil
        self.saveQueue.async {
            self.write(envelope)
        }
    }
    saveWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
}
```

Also clear `firstPendingSaveAt = nil` in `saveNow()` next to
`saveWorkItem = nil` (a manual flush ends the burst).

**Verify**: `swift build` → exit 0; `swift test` → all existing tests pass.

### Step 3: Tests

In `NoteStoreTests.swift`:

1. Unit tests for the pure helper (no clocks, no waiting):
   - `nextSaveDelay(firstPendingAt: nil, ...)` → equals `debounce`.
   - First pending 0.1s ago, debounce 0.5, ceiling 3.0 → 0.5 (ceiling not
     binding yet).
   - First pending 2.8s ago → 0.2 (ceiling binding).
   - First pending 3.5s ago → 0 (never negative).
2. `testContinuousMutationsStillHitDiskWithinCeiling` (integration, follows
   the polling pattern at `NoteStoreTests.swift:309`): start a
   `Timer.scheduledTimer` (or a repeating `DispatchQueue.main.asyncAfter`
   loop driven by `RunLoop.main.run(until:)`) that calls
   `store.update(id:text:)` every 0.1s; poll the store file every 0.1s while
   pumping the main run loop; assert the file appears within 4.0s of the
   first mutation even though mutations never stop. Keep total test time
   under ~5s.

**Verify**: `swift test --filter NoteStoreTests` → all pass; note the
integration test's duration stays under ~5s.

## Test plan

See step 3 — four cheap pure-function cases plus one bounded integration
test. Model timing assertions on the existing poll-to-deadline pattern, not
fixed sleeps.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0; new tests pass; full suite still completes in seconds
- [ ] `grep -n "maxSaveDeferral\|nextSaveDelay\|firstPendingSaveAt" Sources/Nickel/Store/NoteStore.swift` shows all three wired as above
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- `scheduleSave` doesn't match the excerpt (beyond 018's error-state lines
  in `write`).
- The integration test proves flaky across 3 consecutive `swift test` runs
  — report timings rather than loosening the assertion past 4.5s.
- You find any caller of `scheduleSave` off the main thread
  (`grep -rn "scheduleSave" Sources/`) — the `firstPendingSaveAt` bookkeeping
  assumes main-thread-only calls.

## Maintenance notes

- If autosave semantics ever change (e.g. save-on-panel-close), `saveNow()`
  already resets the burst; keep that invariant.
- Reviewer: the work item captures `self` strongly via `guard let self` from
  a `weak` capture — unchanged from today; only the scheduling delay and the
  timestamp bookkeeping are new.
- The 3.0s ceiling is a judgment call (6× the debounce). Tuning it is a
  one-line change; don't add a setting for it.
