# Plan 001: Add a CLAUDE.md so agent sessions stop re-deriving the basics

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- CLAUDE.md README.md`
> If `CLAUDE.md` already exists, STOP and report — this plan assumes it doesn't.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

Nickel is implemented largely by AI agents dispatched with briefs. There is no
`CLAUDE.md`, so every session re-derives the build/test commands, the env-var
overrides, and — most costly — the signing caveat that makes rebuilt binaries
lose their Accessibility grant. Capturing these once removes a recurring recon
tax and prevents agents from "fixing" things that are deliberate decisions.

## Current state

- No `CLAUDE.md` or `AGENTS.md` exists anywhere in the repo.
- Facts to capture (all verified against the code at the planned-at commit):
  - Build: `swift build` (SwiftPM, macOS 14+, zero external dependencies — keep it that way).
  - Tests: `swift test` (XCTest, `Tests/NickelTests/`, currently 26 passing tests, runs in seconds).
  - App bundle: `./scripts/build-app.sh` (release build + `.app` in `build/`); `--install` copies to `/Applications/Nickel.app`. Do not run these unless asked — the user rebuilds/installs on request.
  - `NICKEL_STORE_PATH` env var points the store at an alternate JSON file (`Sources/Nickel/Store/NoteStore.swift:36-40`); `NICKEL_DEBUG=1` enables debug logging (`Sources/Nickel/Support/DebugLog.swift:5`).
  - Signing caveat (from README "Signing note", ~line 102): `build-app.sh` signs with a self-signed "Nickel Dev Signing" identity if present, else ad-hoc. Ad-hoc-signed rebuilds are seen as a *new* app by TCC, so the Accessibility grant must be re-given after each rebuild. If double-Shift stops working after a rebuild, that's why.
  - The AX/hotkey capture layer cannot be verified headlessly — tests target `NoteStore` / model logic, not the hotkey/AX layer.
  - Deliberate decisions agents must not "fix": note lists use plain `VStack`, never `LazyVStack` (its per-identity cell cache serves stale note snapshots when rows migrate between sections — see the comment at `Sources/Nickel/Panel/PanelView.swift:312-318`); Nickel is a standard Dock-icon app, not `LSUIElement`; storage is local-only by design (no sync, no cloud).
  - Architecture in one line each: `Sources/Nickel/Store/` = model + JSON persistence; `Sources/Nickel/Panel/` = SwiftUI panel UI + AppKit interop; `Sources/Nickel/Support/` = utilities (settings, updates, markdown conversion, permissions); `AppDelegate.swift` + `HotkeyMonitor.swift` + `CaptureEngine.swift` = app lifecycle and global capture.
  - Bar for all work: standard native macOS behavior per current Apple HIG/docs; prefer subtractive fixes over added machinery.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | all 26 tests pass   |

## Scope

**In scope** (the only file you should create):
- `CLAUDE.md` (repo root)

**Out of scope**:
- README.md — do not restructure it; CLAUDE.md may reference it.
- Any source file.

## Git workflow

- Branch: `advisor/001-claude-md`
- One commit, message style matches repo (imperative sentence, e.g. "Add CLAUDE.md with agent workflow facts").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write CLAUDE.md

Create `CLAUDE.md` at the repo root containing, in this order: a one-line
project description; Commands (build/test/bundle table, with the "don't run
build-app.sh unprompted" note); Environment variables (`NICKEL_STORE_PATH`,
`NICKEL_DEBUG`); Architecture (the four one-liners above); Deliberate
decisions (VStack-not-LazyVStack with the file:line pointer, Dock-icon app,
local-only storage); Signing & Accessibility caveat; Testing notes (what is
and isn't headlessly verifiable). Keep it under ~80 lines — it's a reference
card, not documentation.

**Verify**: `test -f CLAUDE.md && wc -l CLAUDE.md` → file exists, < 100 lines.

### Step 2: Confirm nothing else changed

**Verify**: `git status --porcelain` → only `CLAUDE.md` (and `plans/README.md` if you updated the status row).

## Test plan

No code changes; no tests. `swift test` must still pass (nothing should have touched code).

## Done criteria

- [ ] `CLAUDE.md` exists at repo root, < 100 lines
- [ ] Every command in it copy-paste-runs successfully
- [ ] `git status` shows no source-file modifications
- [ ] `plans/README.md` status row updated

## STOP conditions

- `CLAUDE.md` already exists (reconcile instead of overwrite — report back).
- Any fact above contradicts what you find in the repo (e.g. README signing
  note moved/changed) — report the discrepancy rather than guessing.

## Maintenance notes

- When commands or env vars change, CLAUDE.md must change in the same commit.
- Reviewer should check no invented facts crept in — every line must trace to
  the repo.
