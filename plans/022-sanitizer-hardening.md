# Plan 022: Harden the captured-HTML sanitizer (charset awareness + SVG/background vectors)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 83d0b46..HEAD -- Sources/Nickel/Support/MarkdownConverter.swift Tests/NickelTests/MarkdownConverterTests.swift`
> Plan 021 also edits this file (font-trait call sites) — that drift is
> expected. If `strippingRemoteResources` or `markdown(fromHTML:)` differ
> from the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S–M
- **Risk**: MED (formatting fidelity on exotic clipboard payloads)
- **Depends on**: plans/021-fontmanager-thread-safety.md (soft — same file; execute in order)
- **Category**: security
- **Planned at**: commit `83d0b46`, 2026-08-02

## Why this matters

Nickel strips fetch-triggering constructs (images, iframes, scripts, CSS
fetches) from captured HTML before handing it to AppKit's WebKit-backed
importer, so that capturing arbitrary copied content can't fire tracking
pixels from a local-only app. Two gaps remain:

1. **Charset bypass**: the sanitizer decodes the pasteboard bytes as UTF-8,
   falling back to ISO-Latin-1. UTF-16-encoded HTML (a BOM or a
   `meta charset` — common for Windows/Office-origin rich clipboard
   content) survives the Latin-1 decode as NUL-interleaved garbage, no
   regex matches, the bytes round-trip unchanged — and the importer then
   honors the declared UTF-16 charset and parses the *original, unstripped*
   markup.
2. **Uncovered vectors**: inline `<svg>` subtrees (`<image href=…>`,
   `<use href=…>`), the legacy `<image>` tag, and the `background=`
   attribute on `body`/`table`/`td` can all trigger fetches but are not in
   the strip lists.

This is defensive maintenance of an existing, deliberate security measure —
the fix is strictly more removal plus correct decoding.

## Current state

`Sources/Nickel/Support/MarkdownConverter.swift`. SwiftPM, macOS 14+, XCTest.

Entry point (`MarkdownConverter.swift:16-25`):

```swift
static func markdown(fromHTML data: Data) -> String? {
    let sanitized = strippingRemoteResources(data)
    let parse = { NSAttributedString(html: sanitized, documentAttributes: nil) }
    let attributed = Thread.isMainThread ? parse() : DispatchQueue.main.sync(execute: parse)
    guard let attributed else { return nil }
    return markdown(from: attributed)
}
```

The sanitizer (`MarkdownConverter.swift:40-95`), abridged to the parts this
plan changes:

```swift
private static func strippingRemoteResources(_ data: Data) -> Data {
    let encoding: String.Encoding
    let text: String
    if let utf8 = String(data: data, encoding: .utf8) {
        encoding = .utf8
        text = utf8
    } else if let latin1 = String(data: data, encoding: .isoLatin1) {
        encoding = .isoLatin1
        text = latin1
    } else {
        return data
    }

    var sanitized = text

    // 1. Void/empty resource elements — remove the tag entirely.
    for tag in ["img", "source", "track", "embed", "input"] { ... }

    // 2. Paired resource elements — remove the tag and its content.
    for tag in ["iframe", "object", "video", "audio", "script"] { ... }

    // 3. <link> tags ...
    // 4. CSS fetches: url(...) → url(about:blank); @import removed.

    guard let reencoded = sanitized.data(using: encoding) else { return data }
    return reencoded
}
```

(The full regex bodies are in the file at the lines noted; they use
`replacingOccurrences(of:with:options:[.regularExpression, .caseInsensitive])`.)

Test file: `Tests/NickelTests/MarkdownConverterTests.swift` — existing tests
build HTML with a `private func html(_ body: String) -> Data { Data(body.utf8) }`
helper and assert on the converted Markdown string. There are existing
sanitizer tests from the previous round (search the file for `img` /
`remote`); match their style.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | exit 0, all pass    |

## Scope

**In scope**:
- `Sources/Nickel/Support/MarkdownConverter.swift` (`strippingRemoteResources`, `markdown(fromHTML:)`, and the access level of the sanitizer)
- `Tests/NickelTests/MarkdownConverterTests.swift`
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- The attribute-walk / inline-markdown code (plan 021's area).
- The RTF path.
- Any attempt at a real HTML parser — the documented regex-over-HTML
  approach stands (see the doc comment at `MarkdownConverter.swift:36-39`:
  over-broad matching is acceptable; reintroducing a fetch is not).

## Git workflow

- Branch: `advisor/022-sanitizer-hardening`
- Commit style: short imperative subject, e.g. "Decode captured HTML by its actual encoding before stripping".
- Do NOT push or open a PR.

## Steps

### Step 1: Make the sanitizer testable

Change `strippingRemoteResources` from `private` to `internal` (tests use
`@testable import Nickel`). No behavior change.

**Verify**: `swift build` → exit 0.

### Step 2: Charset-aware decode

Replace the UTF-8/Latin-1 ladder with detection:

```swift
// Detect the payload's real encoding: BOM first, then NSString's
// detector, then the old UTF-8/Latin-1 ladder as a last resort.
static func decodedHTML(_ data: Data) -> (text: String, encoding: String.Encoding)? {
    // BOMs: FF FE (utf16LE), FE FF (utf16BE), EF BB BF (utf8).
    if data.count >= 2 {
        let b0 = data[data.startIndex], b1 = data[data.index(after: data.startIndex)]
        if b0 == 0xFF, b1 == 0xFE, let s = String(data: data, encoding: .utf16LittleEndian) { return (s, .utf16LittleEndian) }
        if b0 == 0xFE, b1 == 0xFF, let s = String(data: data, encoding: .utf16BigEndian) { return (s, .utf16BigEndian) }
    }
    var converted: NSString?
    let raw = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
    if raw != 0, let converted {
        return (converted as String, String.Encoding(rawValue: raw))
    }
    if let utf8 = String(data: data, encoding: .utf8) { return (utf8, .utf8) }
    if let latin1 = String(data: data, encoding: .isoLatin1) { return (latin1, .isoLatin1) }
    return nil
}
```

In `strippingRemoteResources`, use `decodedHTML`; if it returns nil, keep
the current `return data` fallback. **Always re-encode the sanitized string
as UTF-8** (not the source encoding), and have `markdown(fromHTML:)` pass
the encoding explicitly so a stale `meta charset` in the payload can't
reinterpret the bytes:

```swift
let attributed = NSAttributedString(
    html: sanitized,
    options: [.characterEncoding: String.Encoding.utf8.rawValue],
    documentAttributes: nil
)
```

(Keep the main-thread hop exactly as-is; only the options change. Check the
initializer signature: `NSAttributedString(html:options:documentAttributes:)`.)

**Verify**: `swift test --filter MarkdownConverterTests` → all existing
tests pass (they're UTF-8 in, so behavior is unchanged for them).

### Step 3: Extend the strip lists

- Add `"image"` to the void-tag list (legacy alias of `<img>`).
- Add `"svg"` to the paired-tag list (removes `<svg>…</svg>` subtrees,
  taking `<image href>` / `<use href>` with them).
- Add an attribute strip after the tag passes:

```swift
// background= attributes (body/table/td) that point at remote URLs.
sanitized = sanitized.replacingOccurrences(
    of: "background\\s*=\\s*[\"']?https?://[^\"'\\s>]*[\"']?",
    with: "",
    options: [.regularExpression, .caseInsensitive]
)
```

**Verify**: `swift build` → exit 0.

### Step 4: Tests

Add to `MarkdownConverterTests.swift`:

1. `testSanitizerStripsImgFromUTF16Payload`: build a full HTML document
   string with `<meta charset="utf-16">` and an
   `<img src="https://example.invalid/pixel.gif">` plus visible text; encode
   with `.utf16LittleEndian` **including BOM** (encode via
   `str.data(using: .utf16)` which emits a BOM, or prepend `0xFF 0xFE` to a
   `.utf16LittleEndian` encoding). Call
   `MarkdownConverter.strippingRemoteResources(data)`, decode the result as
   UTF-8, assert it contains the visible text and does NOT contain `<img`
   or `example.invalid`.
2. `testSanitizerStripsInlineSVGImage`: UTF-8 doc with
   `<svg><image href="https://example.invalid/x.png"/></svg>` → sanitized
   output contains no `example.invalid`.
3. `testSanitizerStripsBackgroundAttribute`: `<table background="https://example.invalid/bg.png">`
   → no `example.invalid`.
4. `testUTF16HTMLStillConverts`: end-to-end —
   `MarkdownConverter.markdown(fromHTML: utf16Data)` for a simple
   `<b>bold</b>` UTF-16 document returns a string containing `**bold**`
   (proves the re-encode + explicit-encoding option didn't break parsing).

**Verify**: `swift test --filter MarkdownConverterTests` → all pass;
`swift test` → full suite passes.

## Test plan

See step 4 — four new tests: the charset bypass (the headline fix), the two
new vectors, and one end-to-end UTF-16 conversion. Use `example.invalid`
hosts in test fixtures (guaranteed non-resolvable by RFC 2606) — never a
real domain.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0, including the 4 new tests
- [ ] `strippingRemoteResources` output is always UTF-8 and
      `markdown(fromHTML:)` passes `.characterEncoding` explicitly
- [ ] Strip lists include `image` (void), `svg` (paired), and the
      `background=` attribute pattern
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- The sanitizer/entry-point excerpts don't match the live code (beyond plan
  021's trait changes elsewhere in the file).
- `NSAttributedString(html:options:documentAttributes:)` with
  `.characterEncoding` breaks any existing converter test — report which,
  with the raw output.
- `NSString.stringEncoding(for:...)` misdetects the plain-UTF-8 fixtures
  (existing tests fail at step 2) — report; do not stack heuristics.

## Maintenance notes

- The sanitizer's contract (doc comment, `MarkdownConverter.swift:29-39`):
  over-removal is acceptable, reintroducing a fetch is not. Any future tag
  additions should follow that bias.
- Reviewer: scrutinize the BOM handling and that the re-encode is
  unconditionally UTF-8 — mixed encoding-in/encoding-declared is the whole
  bug class here.
- Deliberately not attempted: `srcset`, `<meta http-equiv="refresh">`, CSS
  `image-set()`. The importer ignores `srcset` without `src`, meta-refresh
  doesn't fire in `NSAttributedString` parsing, and `image-set` is caught by
  the existing `url()` neutralizer when it uses `url()` syntax. Re-evaluate
  if the importer's behavior changes.
