# Plan 033: Recover the hotkeys when Accessibility permission is revoked and re-granted

> **Executor instructions**: Follow this plan step by step, verifying each
> step. On any STOP condition, stop and report. Update this plan's row in
> `plans/README.md` when done — unless a reviewer told you they maintain the
> index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/AppDelegate.swift Sources/Nickel/HotkeyMonitor.swift`
> On change, compare excerpts; mismatch = STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

If the user revokes Nickel's Accessibility permission while the app runs,
the double-tap hotkeys and ⌘V monitoring die silently: no error, no prompt,
no recovery until relaunch. The startup flow only polls for the INITIAL
grant and self-invalidates; `HotkeyMonitor.stop()` exists but has no caller.
This was flagged in the previous audit round and is still present. After
this plan the app notices trust transitions in both directions: on loss it
stops the monitor (releasing dead event taps) and shows the existing
grant-access affordance; on regain it restarts the monitor without relaunch.

## Current state

- `Sources/Nickel/AppDelegate.swift:56-78` — `startHotkeyMonitorOrPromptForAccess()`:
  starts immediately if `Permissions.isTrusted`, else requests and polls:

```swift
trustPollTimer?.invalidate()
trustPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
    guard let self else {
        timer.invalidate()
        return
    }
    guard Permissions.isTrusted else { return }
    timer.invalidate()
    self.trustPollTimer = nil
    HotkeyMonitor.shared.start()
}
```

  One-shot: after the first grant, nothing ever re-checks trust.
- `Sources/Nickel/HotkeyMonitor.swift:108+` — `start()` guards
  `Permissions.isTrusted, globalMonitor == nil` (re-entry safe);
  `stop()` at `:122-132` removes both monitors and `reset()`s — currently
  has zero callers (`grep -rn "\.stop()" Sources Tests` → none for
  HotkeyMonitor).
- `AppDelegate.swift:~435` — the overflow/status menu lazily re-reads
  `!Permissions.isTrusted` to show "Grant Accessibility Access…", so the
  UI affordance for the revoked state already exists.
- `Permissions` (find it: `grep -rn "enum Permissions\|struct Permissions" Sources/`)
  wraps `AXIsProcessTrusted`-family checks.
- `AppDelegate` holds `private var trustPollTimer: Timer?`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | 377 pass |

## Scope

**In scope**:
- `Sources/Nickel/AppDelegate.swift`
- `Sources/Nickel/HotkeyMonitor.swift` (only if a small hook is needed;
  prefer no change)

**Out of scope**:
- `Permissions` itself; the system prompt flow; Settings UI.
- Any attempt to detect revocation via `DistributedNotificationCenter`
  private notification names ("com.apple.accessibility.api" is
  undocumented) — use polling; see Step 1 rationale.

## Git workflow

- Branch: `advisor/033-ax-revocation-recovery` from `main`
  (`git checkout -b advisor/033-ax-revocation-recovery main`).

## Steps

### Step 1: Replace the one-shot poll with a trust-state watcher

In `AppDelegate`, replace `startHotkeyMonitorOrPromptForAccess`'s timer
logic with a single long-lived watcher:

- Keep the initial behavior: if trusted → `HotkeyMonitor.shared.start()`;
  else `Permissions.requestIfNeeded()`.
- Then, in BOTH cases, arm one repeating timer (reuse `trustPollTimer`;
  interval 2.0s, `tolerance = 0.5` — cheap: `AXIsProcessTrusted` is a
  lightweight IPC check) that tracks transitions:

```swift
private var wasTrusted = Permissions.isTrusted

// in the timer body:
let isTrusted = Permissions.isTrusted
guard isTrusted != self.wasTrusted else { return }
self.wasTrusted = isTrusted
if isTrusted {
    HotkeyMonitor.shared.start()
} else {
    HotkeyMonitor.shared.stop()
}
```

- Doc comment must state why polling (no public notification for TCC
  changes) and why the timer never self-invalidates anymore (revocation can
  happen at any time).

**Verify**: `swift build` → exit 0.

### Step 2: Confirm `stop()` is safe and `start()` re-arms

Read `HotkeyMonitor.start()` and confirm: after `stop()`, a later `start()`
re-installs both monitors (the `globalMonitor == nil` guard passes again).
Confirm `reset()` clears tap state. If `start()` has any other one-shot
assumption, fix minimally and note it.

**Verify**: `swift test` → 377 pass.

### Step 3: Tests

`HotkeyMonitor` can't be driven headlessly (needs a real grant), but the
transition LOGIC can: extract the transition decision into a tiny pure
helper on `AppDelegate` or a free function —
`trustTransitionAction(was: Bool, now: Bool) -> TrustAction?` returning
`.start`/`.stop`/nil — and unit test its four combinations in a new
`TrustWatcherTests.swift`. Wire the timer body through it.

**Verify**: `swift test` → 377 + new pass.

## Test plan

- Unit: the four (was, now) combinations.
- Manual (state in report): run the app, revoke Accessibility in System
  Settings → within ~2s double-tap stops responding AND the status menu
  shows "Grant Accessibility Access…"; re-grant → within ~2s double-tap
  works again, no relaunch.

## Done criteria

- [ ] `swift build` exit 0, no warnings
- [ ] `swift test` all pass incl. new transition tests
- [ ] `grep -n "HotkeyMonitor.shared.stop()" Sources/` → exactly one hit
      (the watcher)
- [ ] No self-invalidating trust timer remains (read the diff)
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails.
- `HotkeyMonitor.start()` turns out NOT to be safely restartable after
  `stop()` (some state survives `reset()`); report the specific state.
- The 2s poll shows up in profiling notes/comments as a known cost concern
  in this repo — it shouldn't; if you find such a note, report.

## Maintenance notes

- If Apple ever documents a TCC-change notification, replace the poll.
- Reviewer: check the timer is invalidated in `applicationWillTerminate`
  if the repo does teardown there (match existing timer handling).
