# Plan 006: Stop the ⌘C-fallback capture from clobbering the user's clipboard

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- Sources/Nickel/CaptureEngine.swift`
> On any change, re-verify the excerpt below; on a mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

When Accessibility capture fails, Nickel synthesizes ⌘C, polls the pasteboard
for 250ms, and then *unconditionally* restores its pre-capture snapshot. If
the frontmost app takes longer than 250ms to write the copy (large selection,
slow app, remote desktop), two bad things happen: the capture is falsely
reported as "no selection", and when the late copy finally lands it overwrites
Nickel's restore — silently destroying whatever was on the user's clipboard
before. This is the app's core flow; the failure is silent data loss.

## Current state

- `Sources/Nickel/CaptureEngine.swift`, `captureViaPasteboard()` (lines
  50-74), exactly this today:

```swift
private static func captureViaPasteboard() -> String? {
    let pasteboard = NSPasteboard.general
    let originalChangeCount = pasteboard.changeCount
    let snapshot = snapshotItems(of: pasteboard)

    postCommandC()

    var changed = false
    let deadline = Date().addingTimeInterval(0.25)
    while Date() < deadline {
        if pasteboard.changeCount != originalChangeCount {
            changed = true
            break
        }
        Thread.sleep(forTimeInterval: 0.03)
    }

    let captured = changed ? markdown(from: pasteboard) ?? pasteboard.string(forType: .string) : nil
    restore(snapshot, to: pasteboard)

    guard let text = captured?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        return nil
    }
    return text
}
```

- The whole function is documented "Blocking; call off the main thread"
  (line 12) and is invoked from a `DispatchQueue.global(qos: .userInitiated)`
  block in `AppDelegate` — blocking sleeps here are acceptable.
- `markdown(from:)` (line 80) and `restore(_:to:)` (line 106) are the
  existing helpers; reuse them unchanged.
- The caller (`AppDelegate`) shows a "No text selected" HUD when this returns
  nil, so total latency of the nil path is user-visible.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | all pass            |

## Scope

**In scope**:
- `Sources/Nickel/CaptureEngine.swift` (only `captureViaPasteboard()` and,
  if you extract a poll helper, a private helper beside it)

**Out of scope**:
- `captureViaAccessibility()`, `postCommandC()`, `snapshotItems`, `restore`,
  `markdown(from:)` — unchanged.
- `AppDelegate.swift`, HUD timing, `NoteStore` duplicate-capture logic.

## Git workflow

- Branch: `advisor/006-capture-clipboard-race`
- One commit, imperative message (e.g. "Guard the capture fallback against late pasteboard writes").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Extend the primary poll window

Replace the hardcoded `0.25` deadline with a named constant
`primaryPollWindow: TimeInterval = 1.0` (same 30ms sleep cadence). Keep the
early `break` on change, so the common fast case is unaffected — only the
no-copy path waits longer.

### Step 2: Add a post-restore grace watch

After `restore(snapshot, to: pasteboard)`, when `changed` is still false:

1. Record `restoredChangeCount = pasteboard.changeCount`.
2. Poll for a further `graceWindow: TimeInterval = 0.5` (30ms cadence) for
   `pasteboard.changeCount != restoredChangeCount`.
3. If a late write lands in that window, treat it as the arrived copy:
   read `captured = markdown(from: pasteboard) ?? pasteboard.string(forType: .string)`,
   then call `restore(snapshot, to: pasteboard)` again so the user's
   clipboard is preserved, and return the captured text through the existing
   trim/empty guard.
4. If nothing lands, return nil as today.

This both recovers the capture and re-protects the clipboard; the only
user-visible cost is that the "No text selected" HUD can take ~1.5s instead
of ~0.25s, and that a *user-initiated* copy performed within 0.5s of a failed
capture would be reverted — acceptable because the user physically just
double-tapped Shift. Add a short comment in the code stating exactly this
trade-off (constraint, not narration).

**Verify**: `swift build` → exit 0.

### Step 3: Manual verification script (report results; needs a human/GUI session)

If you are running where the app can be exercised (otherwise record these as
untested in your report):
1. Copy a known string ("SENTINEL"), select text in another app where AX
   capture works — confirm capture works and clipboard still holds SENTINEL.
2. With nothing selected anywhere, double-tap left Shift — "No text
   selected" HUD appears (delayed up to ~1.5s) and clipboard still SENTINEL.

**Verify**: `swift test` → all pass (no behavioral coverage exists for this
path; the suite must simply stay green).

## Test plan

No automated tests: the path is inherently bound to the live system
pasteboard and synthetic key events, and a unit test would clobber the
developer's clipboard. Manual checks in Step 3 stand in. (Extracting a
testable poll-state machine was considered and rejected as machinery
disproportionate to the ~20 lines involved.)

## Done criteria

- [ ] `swift build` exits 0; `swift test` all pass
- [ ] `captureViaPasteboard()` contains no unconditional restore-then-return
      on the timeout path without the grace watch
- [ ] Constants `primaryPollWindow` / `graceWindow` exist (no magic 0.25)
- [ ] `git status` shows only `CaptureEngine.swift` modified (plus plans index)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The current code no longer matches the excerpt (someone already changed
  the timing logic).
- The fix seems to require touching `AppDelegate` or the HUD — that's scope
  creep; report instead.

## Maintenance notes

- If users report sluggish "No text selected" feedback, tune
  `primaryPollWindow`/`graceWindow` — they encode a latency-vs-data-loss
  trade-off; do not remove the second restore.
- Reviewer: scrutinize that the fast path (copy lands < 1s) is byte-for-byte
  the old behavior, and that both exits restore the snapshot exactly once
  per write.
