# Plan 032: Replace deprecated activation calls and fix the stale activation comments

> **Executor instructions**: Follow this plan step by step, verifying each
> step. On any STOP condition, stop and report. Update this plan's row in
> `plans/README.md` when done — unless a reviewer told you they maintain the
> index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/Panel/PanelView.swift Sources/Nickel/Panel/NoteEditorWindowManager.swift Sources/Nickel/Support/UpdateChecker.swift Sources/Nickel/Panel/FloatingPanel.swift Sources/Nickel/AppDelegate.swift`
> On change, compare excerpts; mismatch = STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

`NSApp.activate(ignoringOtherApps:)` is deprecated since macOS 14; under
cooperative activation the `ignoringOtherApps: true` promise is not honored,
so the seven remaining call sites can leave their window BEHIND the
frontmost app (the attach-files open panel, update alerts, the ⌘↩ editor
window). The codebase already contains the correct modern pattern —
`FloatingPanel.activateForSummon()` — and two files already use the plain
`NSApp.activate()`. Separately, three comments justify activation behavior
with premises that are false ("the panel stays a `.nonactivatingPanel`" —
it deliberately is NOT; a "Show Dock Icon" setting that doesn't exist),
which invites the next maintainer to mis-reason in exactly this area.

## Current state

- The modern exemplar, `Sources/Nickel/Panel/FloatingPanel.swift:496-504`:

```swift
private func activateForSummon() {
    guard !NSApp.isActive else { return }
    if let front = NSWorkspace.shared.frontmostApplication,
       front != .current,
       NSRunningApplication.current.activate(from: front, options: []) {
        return
    }
    NSApp.activate()
}
```

- Deprecated call sites (`grep -rn "activate(ignoringOtherApps" Sources/Nickel`):
  - `Sources/Nickel/Panel/PanelView.swift:982` (before `NSOpenPanel.runModal`)
  - `Sources/Nickel/Panel/NoteEditorWindowManager.swift:35`, `:59`
  - `Sources/Nickel/Support/UpdateChecker.swift:104`, `:120`, `:129`, `:138`
- Stale comments:
  - `FloatingPanel.swift:556-558` — sendEvent doc comment claims "The panel
    stays a `.nonactivatingPanel`…"; the init at `FloatingPanel.swift:41-48`
    documents the opposite decision at length (that block is the truth).
  - `PanelView.swift:976-979` — claims "The panel is a nonactivating panel,
    so `NSOpenPanel` needs the app explicitly activated first."
  - References to a "Show Dock Icon" setting that doesn't exist:
    `FloatingPanel.swift:374`, `FloatingPanel.swift:554-559`,
    `AppDelegate.swift:501-503` (verify each with
    `grep -n "Show Dock Icon" Sources/Nickel -r`); `SettingsView.swift` has
    no such toggle and `setActivationPolicy` appears only in `main.swift`'s
    UIProbe branch.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0, **no deprecation warnings** |
| Tests | `swift test` | 377 pass |
| Grep gate | `grep -rn "ignoringOtherApps" Sources/` | no matches |

## Scope

**In scope**:
- The seven call sites' files (PanelView, NoteEditorWindowManager,
  UpdateChecker)
- `Sources/Nickel/Panel/FloatingPanel.swift` (extract the helper; fix
  comments)
- `Sources/Nickel/AppDelegate.swift` (stale comment only)
- New file `Sources/Nickel/Support/AppActivation.swift`

**Out of scope**:
- Any behavioral change to WHEN activation is requested — same call sites,
  same conditions, only the mechanism changes.
- The `sendEvent` click-to-activate logic itself (only its comment).
- Adding a "Show Dock Icon" setting — the comments get corrected instead.

## Git workflow

- Branch: `advisor/032-modern-activation` from `main`
  (`git checkout -b advisor/032-modern-activation main`).

## Steps

### Step 1: Shared helper

Create `Sources/Nickel/Support/AppActivation.swift`:

```swift
import AppKit

/// Cooperative activation (macOS 14+): ask the frontmost app to yield.
/// `activate(from:)` names the yielding app, which the system honors far
/// more often than a bare request; the bare `activate()` remains a
/// fallback. Replaces the deprecated `activate(ignoringOtherApps:)`, whose
/// "ignoring" promise cooperative activation no longer keeps.
enum AppActivation {
    static func activate() {
        guard !NSApp.isActive else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front != .current,
           NSRunningApplication.current.activate(from: front, options: []) {
            return
        }
        NSApp.activate()
    }
}
```

Rewrite `FloatingPanel.activateForSummon()` to call `AppActivation.activate()`
(keep the method as the panel-local name; delete its duplicated body).

**Verify**: `swift build` → exit 0.

### Step 2: Replace the seven call sites

Each `NSApp.activate(ignoringOtherApps: true)` becomes
`AppActivation.activate()`. Do not reorder surrounding code.

**Verify**: `grep -rn "ignoringOtherApps" Sources/` → no matches;
`swift build` → exit 0 and the previous deprecation warnings are gone.

### Step 3: Correct the stale comments

- `FloatingPanel.swift:556-558`: rewrite to state the true premise — the
  panel is a normal activating panel (per the init comment at :41-48); the
  logic below exists because <read the code and state the actual reason,
  e.g. borderless panels don't get the standard title-bar activation
  affordances>. Keep it short; point to the init comment rather than
  restating it.
- `PanelView.swift:976-979`: the open panel needs the app active because
  the panel window itself may be shown without app activation (summoned via
  the global hotkey while another app is frontmost) — state that, not the
  nonactivating claim.
- The "Show Dock Icon" references at `FloatingPanel.swift:374`, `:554-559`,
  `AppDelegate.swift:501-503`: rewrite each to describe current reality
  (the app always shows a Dock icon; per repo CLAUDE.md that's a deliberate
  decision). If a reference turns out to be load-bearing dead code (an `if`
  on a nonexistent setting rather than a comment), STOP and report.

**Verify**: `grep -rn "nonactivating" Sources/Nickel/Panel/PanelView.swift Sources/Nickel/Panel/FloatingPanel.swift` — remaining hits are only in the
init's "deliberately NOT" block; `grep -rn "Show Dock Icon" Sources/` → no
matches.

### Step 4: Full gate

**Verify**: `swift test` → 377 pass; `NICKEL_UI_PROBE=1 .build/debug/Nickel`
→ all checks passed.

## Test plan

No new XCTests (activation is not headlessly assertable). Manual note for
the human: with another app frontmost, (a) click the paperclip → the file
dialog must come to the front; (b) Check for Updates → alert in front;
(c) ⌘↩ on a note → editor window in front and key.

## Done criteria

- [ ] `grep -rn "ignoringOtherApps" Sources/` → no matches
- [ ] `swift build` exit 0, no deprecation warnings
- [ ] `swift test` 377 pass; probe passes
- [ ] Stale comments corrected (grep gates in Step 3)
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails.
- Any "Show Dock Icon" reference is code, not comment.
- Removing `ignoringOtherApps` at a site demonstrably changes behavior the
  surrounding code depends on (e.g. a comment says the modal MUST run
  without activation fallback) — report.

## Maintenance notes

- CI grep-gate idea (optional follow-up): fail on `ignoringOtherApps` to
  prevent reintroduction.
- Reviewer: the UpdateChecker's four sites run on arbitrary threads? Check
  call context — `AppActivation.activate()` must run on main; add
  `@MainActor`/dispatch if UpdateChecker calls from a background queue.
