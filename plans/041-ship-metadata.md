# Plan 041: Ship metadata — Info.plist keys, build number, README refresh, probe in CI

> **Executor instructions**: Follow this plan step by step, verifying each
> step. On any STOP condition, stop and report. Update this plan's row in
> `plans/README.md` when done — unless a reviewer told you they maintain the
> index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Resources/Info.plist README.md .github/workflows/ci.yml scripts/build-app.sh`
> On change, compare excerpts; mismatch = STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/029-dynamic-hotkey-copy.md (soft — keep hotkey
  wording consistent)
- **Category**: docs / dx
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

Pre-ship hygiene with user-visible consequences: the About panel renders a
blank copyright line; `CFBundleVersion` is a constant `1`, so macOS tooling
(Launch Services, crash reports, the update checker's context) can't tell
builds apart; the README actively misdescribes the app (⌘K "move to
section" — the exact wrong instruction the recent ⌘K/⌃⌘M split exists to
prevent — and "drag-free custom lists" after drag-and-drop shipped); and CI
runs only `swift build`/`swift test` while the geometry probe — built
precisely to catch the list-layer regressions CI can't — is never executed,
so a row-height regression can merge green.

## Current state

- `Resources/Info.plist` — has `CFBundleShortVersionString` (1.5.0) and
  `CFBundleVersion` (`1`); NO `NSHumanReadableCopyright`, NO
  `LSApplicationCategoryType`.
- `scripts/build-app.sh` — assembles the .app (read it to find where
  Info.plist is copied; the build-number stamping goes there).
- `README.md:42` — "…collapse for long notes, and drag-free custom lists
  ("Move to…")."; `README.md:65` — Logbook "opened from the overflow menu
  or the ⌘K…"; `README.md:78` — shortcut table row: `| **⌘K** | Commands,
  or move to section |`; no ⌃⌘M row; no mention of drag-and-drop reorder,
  hotkey customization (Settings pickers), or "Mark notes as done when
  copied".
- `.github/workflows/ci.yml` — jobs: one `test` job on `macos-14` with
  `swift build` + `swift test` only.
- Git user for copyright: "Quang Nguyen" (`git log` author). App is
  local-distribution (no App Store submission planned; category is still
  correct metadata).
- The probe: `NICKEL_UI_PROBE=1 .build/debug/Nickel` — offscreen panel, no
  Accessibility grant needed, exits 0/1 (documented in CLAUDE.md). Not yet
  verified on GitHub runners — treat CI flakiness as possible (see Step 4).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test` | all pass |
| Probe | `NICKEL_UI_PROBE=1 .build/debug/Nickel` | exit 0 |
| Plist lint | `plutil -lint Resources/Info.plist` | OK |

## Scope

**In scope**:
- `Resources/Info.plist`
- `scripts/build-app.sh` (CFBundleVersion stamping ONLY — this repo's
  standing rule says do not RUN this script; editing it is fine, running
  it is not)
- `README.md`
- `.github/workflows/ci.yml`

**Out of scope**:
- Version-number bumps (`CFBundleShortVersionString` stays 1.5.0).
- Release/tagging process, notarization, hardened runtime (settled:
  rejected for local distribution).
- CLAUDE.md (already current).

## Git workflow

- Branch: `advisor/041-ship-metadata` from `main`
  (`git checkout -b advisor/041-ship-metadata main`).

## Steps

### Step 1: Info.plist keys

Add:

```xml
<key>NSHumanReadableCopyright</key>
<string>© 2026 Quang Nguyen</string>
<key>LSApplicationCategoryType</key>
<string>public.app-category.productivity</string>
```

**Verify**: `plutil -lint Resources/Info.plist` → OK.

### Step 2: Build-number stamping

In `scripts/build-app.sh`, where Info.plist lands in the bundle, stamp
`CFBundleVersion` with a monotonic value: `git rev-list --count HEAD` (use
`PlistBuddy` or `plutil -replace` on the COPY inside the bundle, never the
source file). Comment why (Launch Services/crash-report build identity).
DO NOT run the script; verify by shell-reading your edit
(`bash -n scripts/build-app.sh` for syntax) and report that a human/CI run
is owed.

**Verify**: `bash -n scripts/build-app.sh` → exit 0.

### Step 3: README refresh

- `README.md:42`: replace "drag-free custom lists ("Move to…")" with copy
  covering drag-and-drop: reorder notes by dragging; drag across sections
  in Show All; "Move to Section" also available via right-click and ⌃⌘M.
- Shortcut table: `⌘K` → "Commands, or switch section"; add `⌃⌘M` → "Move
  selection to a section". Check `README.md:65`'s ⌘K reference still reads
  correctly after the change.
- Add feature bullets: customizable double-tap hotkeys (Settings ▸ pickers;
  wording consistent with plan 029's "double-tap <key>" phrasing) and the
  "Mark notes as done when copied" setting.
- Sweep the whole README for other staleness against the current app
  (`grep -n "⌘" README.md` and compare each against
  `Sources/Nickel/Panel/ShortcutsOverlay.swift`'s rows); fix what you find,
  list every fix in the report.

**Verify**: `grep -n "drag-free" README.md` → no matches;
`grep -n "⌃⌘M" README.md` → present.

### Step 4: Probe in CI

In `.github/workflows/ci.yml`, after the Test step:

```yaml
      - name: UI geometry probe
        run: |
          NICKEL_UI_PROBE=1 timeout 120 .build/debug/Nickel
```

(`swift build` already produced `.build/debug/Nickel` in the Build step —
confirm the Build step builds debug (plain `swift build` does)). The
`timeout` guards a hung runloop; 120s is generous (locally it's ~5s).
Note in the workflow file: if this step proves flaky on runners, demote to
non-blocking (`continue-on-error: true`) — do NOT preemptively demote.

**Verify**: `NICKEL_UI_PROBE=1 timeout 120 .build/debug/Nickel; echo $?` →
0 locally. CI verification is owed on first push; state that in the report.

## Test plan

No XCTest changes. Gates: plutil lint, bash -n, greps, local probe run.

## Done criteria

- [ ] `plutil -lint` OK; copyright + category keys present
- [ ] `bash -n scripts/build-app.sh` exit 0; stamping logic present, source
      plist untouched by it
- [ ] README: no "drag-free", ⌘K corrected, ⌃⌘M present, new features listed
- [ ] ci.yml has the probe step
- [ ] `swift test` all pass (unchanged)
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails.
- `scripts/build-app.sh` structure makes in-bundle stamping non-obvious
  (e.g. plist generated, not copied) — report the actual mechanism instead
  of guessing.
- README claims a feature you cannot find in the code — flag it, don't
  document it.

## Maintenance notes

- On release-tagging, the existing rule stands: tag must match
  `CFBundleShortVersionString` (update checker). `CFBundleVersion` is now
  automatic — never hand-edit it.
- First CI run after merge: watch the probe step; if flaky, open an issue
  before demoting it.
