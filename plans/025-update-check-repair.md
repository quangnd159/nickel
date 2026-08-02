# Plan 025: Make "Check for Updates" honest — test the comparator, handle the no-releases case

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 83d0b46..HEAD -- Sources/Nickel/Support/UpdateChecker.swift Tests/NickelTests/UpdateCheckerTests.swift`
> If either file changed since this plan was written, compare the excerpts
> below against the live code; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `83d0b46`, 2026-08-02

## Why this matters

The GitHub repo (`quangnd159/nickel`) currently has **zero releases**
(verified against the live API on 2026-08-02: `releases/latest` returns
404). So today, every "Check for Updates…" ends in a warning alert reading
"Couldn't check for updates. The server responded with status 404." — an
advertised feature that visibly fails, presenting a normal state as an
error. Separately, the version comparator treats any non-numeric component
as `0` (`"1.0.1-beta"` == `"1.0.0"` at the third component becomes
`1-beta → 0`, so it reads as 1.0.0 — *older* than reality), and it has no
tests at all; the existing `UpdateCheckerTests` cover only the URL
validator. This plan: (1) treats 404-on-latest as "no releases published"
with a friendly message, (2) makes the comparator tolerate `v`-prefixes and
numeric-prefixed components, and (3) tests it.

## Current state

`Sources/Nickel/Support/UpdateChecker.swift` (119 lines, whole file is
relevant). SwiftPM, macOS 14+, XCTest.

Response handling (`UpdateChecker.swift:28-52`):

```swift
private static func handleResponse(data: Data?, response: URLResponse?, error: Error?) {
    if let error {
        presentError(error.localizedDescription)
        return
    }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
        let status = (response as? HTTPURLResponse)?.statusCode
        presentError(status.map { "The server responded with status \($0)." } ?? "The server returned an unexpected response.")
        return
    }

    do {
        let release = try JSONDecoder().decode(Release.self, from: data)
        let latestVersion = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        if compareVersions(latestVersion, isNewerThan: currentVersion) {
            presentUpdateAvailable(version: latestVersion, releaseURL: release.htmlURL)
        } else {
            presentUpToDate()
        }
    } catch {
        presentError(error.localizedDescription)
    }
}
```

The comparator (`UpdateChecker.swift:57-70`):

```swift
private static func compareVersions(_ lhs: String, isNewerThan rhs: String) -> Bool {
    let lhsParts = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let rhsParts = rhs.split(separator: ".").map { Int($0) ?? 0 }
    let count = max(lhsParts.count, rhsParts.count)

    for index in 0..<count {
        let lhsValue = index < lhsParts.count ? lhsParts[index] : 0
        let rhsValue = index < rhsParts.count ? rhsParts[index] : 0
        if lhsValue != rhsValue {
            return lhsValue > rhsValue
        }
    }
    return false
}
```

Alert helpers `presentUpdateAvailable` / `presentUpToDate` / `presentError`
are at `:85-118`; `validatedReleaseURL` at `:75-83` is `static` (already
testable) — that's the pattern for exposure: plain `static` on the enum,
tested via `@testable import Nickel` in
`Tests/NickelTests/UpdateCheckerTests.swift` (7 existing tests; match their
naming style, e.g. `testRejectsNonHTTPSScheme`).

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | exit 0, all pass    |

## Scope

**In scope**:
- `Sources/Nickel/Support/UpdateChecker.swift`
- `Tests/NickelTests/UpdateCheckerTests.swift`
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- Cutting a GitHub release, bumping `Resources/Info.plist` versions, or
  editing `scripts/build-app.sh` — release management is the maintainer's
  call (noted in Maintenance).
- The deprecated `NSApp.activate(ignoringOtherApps:)` calls in the alert
  helpers — known separate item, deliberately not fixed here.
- Any networking change beyond the 404 branch (no retries, no caching).

## Git workflow

- Branch: `advisor/025-update-check-repair`
- Commit style: short imperative subject, e.g. "Treat a missing latest release as up to date".
- Do NOT push or open a PR.

## Steps

### Step 1: Friendly no-releases branch

In `handleResponse`, before the generic non-200 guard, special-case 404:

```swift
if let http = response as? HTTPURLResponse, http.statusCode == 404 {
    presentNoReleases()
    return
}
```

with a new private helper matching the style of `presentUpToDate`
(`:101-108`): non-warning alert, message "You're up to date.", informative
text "No releases have been published yet." — same
`NSApp.activate` + `runModal` shape as its siblings.

**Verify**: `swift build` → exit 0.

### Step 2: Tolerant, testable comparator

1. Extract the `v`-prefix strip into an internal helper and loosen component
   parsing to take leading digits:

```swift
/// "v1.2.3" -> "1.2.3"; leaves non-prefixed tags alone.
static func normalizedVersion(_ tag: String) -> String {
    tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
}

/// Numeric, component-wise comparison. Non-numeric suffixes inside a
/// component contribute their leading digits ("1-beta" -> 1); a fully
/// non-numeric component counts as 0.
static func compareVersions(_ lhs: String, isNewerThan rhs: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
    ...same loop as today over parts(lhs)/parts(rhs)...
}
```

(Change `private static` → `static` on `compareVersions`; keep the doc
comment updated.)

2. Use `normalizedVersion(release.tagName)` in `handleResponse` in place of
   the inline `hasPrefix("v")` ternary.

**Verify**: `swift build` → exit 0.

### Step 3: Tests

Add to `UpdateCheckerTests.swift`:

- `testCompareDoubleDigitComponents`: `compareVersions("1.10.0", isNewerThan: "1.2.0")` → true.
- `testCompareEqualWithMissingTrailingComponents`: `"1.2"` vs `"1.2.0"` → false both directions.
- `testComparePreReleaseSuffixKeepsNumericPrefix`: `"1.0.1-beta"` vs `"1.0.0"` → true (the fix; was false).
- `testCompareGarbageComponentCountsAsZero`: `"1.x.0"` vs `"1.0.0"` → false both directions.
- `testNormalizedVersionStripsVPrefixOnly`: `"v1.2.3"` → `"1.2.3"`; `"1.2.3"` unchanged; `"version1"` unchanged... note `"version1".hasPrefix("v")` is true, so it becomes `"ersion1"` — decide: keep the simple strip (document it) OR strip only when the remainder starts with a digit. Prefer the latter (one extra condition); assert `"version1"` is left unchanged.

**Verify**: `swift test --filter UpdateCheckerTests` → all pass (7 existing + 5 new).

## Test plan

See step 3. The 404 branch is alert UI (`runModal`) and stays untested —
consistent with how the other alert helpers are treated; the comparator and
normalizer carry the tests.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0; new comparator tests pass
- [ ] `handleResponse` has an explicit 404 branch that does not use the warning style
- [ ] `compareVersions` and `normalizedVersion` are internal `static` and tested
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- The excerpts don't match the live code.
- You're tempted to make network calls in tests — don't; the comparator
  tests are pure and the 404 branch is untested by design.

## Maintenance notes

- **For the maintainer, out of this plan's scope**: the feature only becomes
  fully real once a `v1.0.0` GitHub release exists, and nothing in
  `scripts/build-app.sh` bumps `CFBundleShortVersionString` — decide a
  single source of truth for the version when cutting the first release.
- Reviewer: confirm the 404 alert copy doesn't claim an update exists;
  "up to date" is the honest framing when nothing has been published.
- If GitHub ever changes `releases/latest` 404 semantics (e.g. drafts
  only), this branch reads as up-to-date — acceptable for a manual check.
