# Plan 013: Strip remote-resource references from captured HTML before parsing

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- Sources/Nickel/Support/MarkdownConverter.swift Tests/NickelTests/`
> On any change to `MarkdownConverter.swift`, re-verify the excerpts; on a
> mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: 004-markdown-converter-tests.md (regression net — REQUIRED first)
- **Category**: security
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

`MarkdownConverter.markdown(fromHTML:)` hands captured pasteboard HTML to
`NSAttributedString(html:documentAttributes:)`, whose WebKit-backed importer
can resolve external resource references (image tags, linked stylesheets)
*during the parse*. Capture fires on a double-Shift over whatever the user
selected in any app, so copying a web/email snippet can trigger outbound
requests to third parties embedded in that content — a tracking-pixel /
beaconing leak the user never opted into, in an app whose pitch is
local-only. Removing resource-loading elements before the parse closes it
without touching the conversion logic.

## Current state

- `Sources/Nickel/Support/MarkdownConverter.swift:16-24`:

```swift
static func markdown(fromHTML data: Data) -> String? {
    // AppKit's HTML importer must run on the main thread (it synchronizes
    // with it internally and times out when called from elsewhere), but
    // capture runs on a background queue — hop over if needed.
    let parse = { NSAttributedString(html: data, documentAttributes: nil) }
    let attributed = Thread.isMainThread ? parse() : DispatchQueue.main.sync(execute: parse)
    guard let attributed else { return nil }
    return markdown(from: attributed)
}
```

- What the converter actually *uses* from the parse (verified by reading the
  full file): fonts/traits (bold, italic, monospace, heading sizes), link
  attributes, `NSTextList` paragraph styles, and `headIndent`. It never
  emits images — so dropping image elements loses nothing in the output.
- CSS caution: the importer resolves `<style>` blocks and inline styles into
  those fonts/paragraph attributes. Stripping `<style>` wholesale could
  change heading/bold detection on real pages. Therefore this plan strips
  only *resource-fetching* constructs, not styling.
- Regression net: `Tests/NickelTests/MarkdownConverterTests.swift` from
  Plan 004 must exist and pass before you start.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | all pass            |

## Scope

**In scope**:
- `Sources/Nickel/Support/MarkdownConverter.swift` (a private sanitizer +
  one call in `markdown(fromHTML:)`)
- `Tests/NickelTests/MarkdownConverterTests.swift` (add sanitizer tests)

**Out of scope**:
- The RTF path, the attribute-walking conversion logic, `CaptureEngine`.
- Network-layer blocking (proxies, ATS keys) — a plist-level ATS lockdown
  would also break `UpdateChecker`; rejected.

## Git workflow

- Branch: `advisor/013-html-import-remote-resources`
- One commit, imperative message (e.g. "Strip resource-loading elements from captured HTML").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the sanitizer

Add a private static function `strippingRemoteResources(_ data: Data) -> Data`
that decodes the data as text (try UTF-8 first, fall back to
`NSAttributedString`'s default Latin-1 assumption via
`String(data:encoding:.isoLatin1)`; if both fail, return the data unchanged),
applies case-insensitive regex removals, and re-encodes with the *same*
encoding it decoded with:

1. Remove empty/void resource elements entirely:
   `<img …>`, `<source …>`, `<track …>`, `<embed …>`, `<input …>`
   (pattern like `<img\b[^>]*>` with `.caseInsensitive`).
2. Remove paired resource elements with their content:
   `<iframe …>…</iframe>`, `<object …>…</object>`, `<video …>…</video>`,
   `<audio …>…</audio>`, `<script …>…</script>`
   (pattern like `<iframe\b[^>]*>.*?</iframe>` with `.dotMatchesLineSeparators`).
3. Remove `<link …>` tags (stylesheet/prefetch fetches).
4. Neutralize CSS fetches while keeping styling: inside the remaining text,
   replace `url( … )` occurrences whose argument starts with `http`, `//`,
   or `https` with `url(about:blank)`, and delete `@import` statements
   (`@import[^;]*;`).

Regex-over-HTML is acceptable here (state this in a comment): the goal is
removing fetch triggers from importer input, not faithful HTML parsing — an
over-broad match degrades formatting fidelity, never security.

### Step 2: Call it

In `markdown(fromHTML:)`, parse `strippingRemoteResources(data)` instead of
`data`. No other changes.

**Verify**: `swift build` → exit 0.

### Step 3: Tests

In `MarkdownConverterTests.swift` add:

1. `<p>hello <img src="https://tracker.example/p.gif"> world</p>` → output
   contains `hello` and `world`, does not contain `tracker.example`.
2. `<style>h1 { color: red; background: url(https://tracker.example/b.png) }</style><h1>Title</h1>`
   → still produces `# Title`; output contains no `tracker.example`.
3. `<b>bold</b> <a href="https://example.com">link</a>` → unchanged behavior
   (`**bold**`, `[link](https://example.com)`) — links are markdown output,
   not fetches; they must survive.
4. All pre-existing Plan 004 tests unchanged and passing.

**Verify**: `swift test` → all pass.

## Test plan

Step 3 above. Note the tests assert on converter *output* (the observable
contract), not on the sanitizer's intermediate string — implementation may
evolve. A packet-capture verification was considered and left out (not
automatable here); the element-removal approach makes fetches structurally
absent from importer input instead.

## Done criteria

- [ ] `swift build` exits 0; `swift test` all pass (Plan 004 suite + ≥ 3 new)
- [ ] `markdown(fromHTML:)` parses sanitized data only
- [ ] Links in output still work (test 3)
- [ ] `git status` shows only the two in-scope files modified (plus plans index)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `MarkdownConverterTests.swift` doesn't exist (Plan 004 not landed) — hard
  dependency.
- A Plan 004 test breaks and the fix would require loosening a *conversion*
  assertion (bold/list/heading output changed) — the sanitizer altered
  parsing more than intended; report with the failing case.
- Encoding round-trip proves lossy for a test fixture (mojibake in output) —
  report; do not force UTF-8.

## Maintenance notes

- If Apple ever ships a documented "no remote loads" option for the HTML
  importer, prefer deleting this sanitizer in favor of it (subtractive fix).
- Reviewer: check the regexes are anchored to tag boundaries (`\b`, `[^>]*`)
  so ordinary text mentioning "img" is untouched, and that `<a href>` is
  *not* in the removal list.
