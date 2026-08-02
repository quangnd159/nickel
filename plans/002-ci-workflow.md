# Plan 002: Add a GitHub Actions workflow running swift build + swift test

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- .github Package.swift`
> If a `.github/workflows/` directory already exists, STOP and report.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

`swift build` and `swift test` are both green and fast (26 tests, seconds),
but nothing runs them automatically — a broken build or failing test lands on
`main` unless a human happens to run the commands. A minimal CI workflow makes
the existing verification baseline self-enforcing, which every other plan in
this directory then benefits from.

## Current state

- No `.github/` directory, no CI config of any kind (verified at the
  planned-at commit).
- `Package.swift` declares `platforms: [.macOS(.v14)]` and swift-tools-version
  5.9 — the runner must be a macOS image with Xcode 15+ / Swift 5.9+.
- The repo's remote hosting was not verified during planning. If there is no
  GitHub remote (`git remote -v` empty or non-GitHub), the workflow file is
  still harmless but can't be exercised; note that in your report.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | all 26 tests pass   |

## Scope

**In scope** (the only file you should create):
- `.github/workflows/ci.yml`

**Out of scope**:
- `scripts/build-app.sh` — CI should not build/sign the app bundle (signing
  identities don't exist on runners).
- Adding lint/format steps — deliberately out (rejected during audit).

## Git workflow

- Branch: `advisor/002-ci-workflow`
- One commit, imperative message (e.g. "Add CI workflow running swift build and test").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write the workflow

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: swift build
      - name: Test
        run: swift test
```

**Verify**: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"` → exit 0 (or, if PyYAML is unavailable, `ruby -ryaml -e "YAML.load_file('.github/workflows/ci.yml')"` → exit 0).

### Step 2: Sanity-check locally

The workflow only runs the two commands below; confirm they pass locally so
the first CI run can't fail for repo reasons.

**Verify**: `swift build && swift test` → exit 0, 26 tests pass.

## Test plan

No new tests — this plan wires the existing suite into CI.

## Done criteria

- [ ] `.github/workflows/ci.yml` exists and parses as YAML
- [ ] `swift build && swift test` passes locally
- [ ] `git status` shows only the new workflow file
- [ ] `plans/README.md` status row updated

## STOP conditions

- A CI config already exists anywhere (including non-GitHub CI files).
- `swift test` fails locally before your change — that's a pre-existing
  breakage this plan must not paper over.

## Maintenance notes

- If the test count grows meaningfully slower or flaky UI-adjacent tests are
  added later, revisit runner choice/timeouts then — not now.
- Reviewer: confirm the runner image is macOS 14+ (Swift 5.9 requirement).
