# Plan 014: Validate the release URL before handing it to NSWorkspace.open

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- Sources/Nickel/Support/UpdateChecker.swift Tests/NickelTests/`
> On any change to `UpdateChecker.swift`, re-verify the excerpt; on a
> mismatch, STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

"Check for Updates…" decodes `html_url` from the GitHub Releases API response
and passes it straight to `NSWorkspace.shared.open(url)`, which hands *any*
scheme to the OS. Exploitation requires tampering upstream (compromised repo
or network trust), so impact is low-probability — but the fix is a two-line
allowlist and the "View Release" button frames whatever opens as trustworthy.
Cheap defense in depth.

## Current state

- `Sources/Nickel/Support/UpdateChecker.swift`:
  - `Release` decodes `tag_name`/`html_url` (lines 7-15) from
    `https://api.github.com/repos/quangnd159/nickel/releases/latest` (line 17).
  - `presentUpdateAvailable(version:releaseURL:)` (lines 72-82) ends with:

```swift
if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: releaseURL) {
    NSWorkspace.shared.open(url)
}
```

  - `UpdateChecker` is an `enum` of static methods; alerts are built inline;
    errors go through `presentError(_:)` (lines 93-101).

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | all pass            |

## Scope

**In scope**:
- `Sources/Nickel/Support/UpdateChecker.swift`
- `Tests/NickelTests/UpdateCheckerTests.swift` (create, small)

**Out of scope**:
- The version-comparison logic, alert copy, the API URL, networking code.

## Git workflow

- Branch: `advisor/014-update-url-validation`
- One commit, imperative message (e.g. "Allowlist the release URL before opening it").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the validator and gate the open

Add an internal (not private — tests need it) static helper:

```swift
/// Only ever open the release page we expect: https, on github.com or a
/// subdomain. Anything else in `html_url` means the response was tampered
/// with or the API changed shape — don't hand it to the OS.
static func validatedReleaseURL(_ string: String) -> URL? {
    guard let url = URL(string: string),
          url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(),
          host == "github.com" || host.hasSuffix(".github.com") else {
        return nil
    }
    return url
}
```

In `presentUpdateAvailable`, replace the `URL(string: releaseURL)` binding
with `validatedReleaseURL(releaseURL)`; when it returns nil after the button
press, call `presentError("The release page address was unexpected.")`
instead of opening.

**Verify**: `swift build` → exit 0.

### Step 2: Tests

Create `UpdateCheckerTests.swift` (`@testable import Nickel`) covering
`validatedReleaseURL`:

- `https://github.com/quangnd159/nickel/releases/tag/v1.0.1` → non-nil
- `http://github.com/...` → nil (scheme)
- `https://evil.example/github.com` → nil (host)
- `https://notgithub.com/x` → nil (suffix must include the dot boundary)
- `file:///etc/hosts` → nil
- not-a-URL garbage → nil

**Verify**: `swift test --filter UpdateCheckerTests` → all pass.

## Test plan

Step 2 (≥ 6 tests) on the pure validator. The alert flow itself stays
manual-only (modal `NSAlert` isn't unit-testable headlessly).

## Done criteria

- [ ] `swift build` exits 0; `swift test` all pass incl. `UpdateCheckerTests`
- [ ] `grep -n "NSWorkspace.shared.open" Sources/Nickel/Support/UpdateChecker.swift`
      → exactly 1 match, guarded by `validatedReleaseURL`
- [ ] `git status` shows only the two in-scope files modified (plus plans index)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The excerpt no longer matches (open path already changed).
- You're tempted to make `validatedReleaseURL` private and test via the
  alert flow — don't; report if internal visibility is somehow unacceptable.

## Maintenance notes

- If releases ever move off GitHub, the allowlist must move with them — the
  helper's doc comment is the reminder.
- Reviewer: check the host test uses a dot-boundary suffix match (the
  `notgithub.com` test pins it).
