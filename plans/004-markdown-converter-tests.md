# Plan 004: Add a MarkdownConverter test suite (HTML/RTF → Markdown)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- Sources/Nickel/Support/MarkdownConverter.swift Tests/NickelTests/`
> On any change to `MarkdownConverter.swift`, re-verify the "Current state"
> excerpts before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

`MarkdownConverter` runs on every rich-text capture — it's how bold, links,
lists, headings, and code blocks survive into a note. It is ~200 lines of
attribute-walking heuristics with zero tests, so a regression silently
corrupts what the user just captured. It is also a prerequisite safety net for
Plan 013, which changes the HTML input this code receives.

## Current state

- `Sources/Nickel/Support/MarkdownConverter.swift` — the converter. Public
  surface (both return `String?`):
  - `markdown(fromHTML data: Data)` (line 16) — parses via
    `NSAttributedString(html:documentAttributes:)`. Note the comment at
    lines 17-21: the HTML importer must run on the main thread; the function
    hops via `DispatchQueue.main.sync` when needed. XCTest runs test methods
    on the main thread, so tests can call it directly.
  - `markdown(fromRTF data: Data)` (line 26) — parses via the RTF importer.
- Conversion rules (from reading the implementation, lines 37-197):
  - Bold runs → `**…**`, italic → `*…*`, both nest as `**\*…\***`? No —
    italic marker is applied first, then bold wraps it (lines 155-160), so
    bold+italic yields `***text***`-equivalent nesting `**` around `*`.
  - Monospaced runs (`.monoSpace` trait or family name containing
    menlo/monaco/courier/"sf mono"/consolas, lines 176-182) → `` `…` ``
    inline, or a fenced ``` block when a whole paragraph is monospaced and
    not a list item (lines 63-66, 48-52).
  - Links → `[text](url)` (lines 163-167).
  - Headings: bold font with pointSize ≥ 20 → `#`, 17-<20 → `##`, 15-<17 →
    `###` (lines 187-197); heading text suppresses `**` markers (line 88).
  - Lists: paragraphs with `NSTextList` paragraph styles → `- ` or `1. `
    markers with two-space indent per nesting level; the importer's baked-in
    "\t<marker>\t" prefix is skipped via `rangeAfterListMarker` (lines
    69-84, 121-130). Consecutive list items join with single newlines; other
    blocks join with blank lines (lines 104-113).
  - Blockquotes: paragraph `headIndent > 0` → `> ` prefix (lines 95-98).
  - Leading/trailing spaces of a run stay *outside* the markers (lines
    138-146).
  - No escaping of literal `*`/`_`/backticks — deliberate (header comment,
    lines 10-14). Do not "fix" this.
- Test exemplar: `Tests/NickelTests/NoteStoreTests.swift` (plain XCTest,
  `@testable import Nickel`).

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | all pass            |

## Scope

**In scope**:
- `Tests/NickelTests/MarkdownConverterTests.swift` (create)

**Out of scope**:
- `Sources/Nickel/Support/MarkdownConverter.swift` — characterization only;
  if output looks wrong, capture actual behavior in the test with a comment,
  or STOP and report if it's an outright bug.

## Git workflow

- Branch: `advisor/004-markdown-converter-tests`
- One commit, imperative message (e.g. "Add MarkdownConverter test suite").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: HTML-path tests

Create `MarkdownConverterTests.swift` (`import XCTest`, `@testable import
Nickel`). Drive `MarkdownConverter.markdown(fromHTML:)` with small HTML
strings encoded as UTF-8 `Data`. The importer's exact output attributes can
vary slightly across macOS versions, so prefer assertions on the produced
markdown substrings (`XCTAssertTrue(result.contains("**bold**"))`) over
whole-string equality where layout whitespace is involved. Cases:

- `<b>bold</b>` → contains `**bold**`
- `<i>italic</i>` → contains `*italic*`
- `<a href="https://example.com">link</a>` → contains `[link](https://example.com)`
- `<h1>Title</h1>` → begins with `# Title` (and no `**` around it)
- `<ul><li>one</li><li>two</li></ul>` → contains `- one\n- two` (single
  newline between items, marker not duplicated)
- `<ol><li>first</li><li>second</li></ol>` → contains `1. first\n2. second`
- `<code>x = 1</code>` (inline, inside a sentence) → contains `` `x = 1` ``
- `<blockquote>quoted</blockquote>` → contains `> quoted`
- Plain text with literal asterisks `two * three` → survives unchanged (no
  escaping added)
- Empty/whitespace-only HTML → nil or empty result (assert it doesn't crash;
  match actual behavior)

### Step 2: RTF-path and attributed-string fixtures

For `markdown(fromRTF:)`, build an `NSMutableAttributedString` fixture (e.g.
a paragraph in `NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)`)
and convert it to RTF data via
`attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])`,
then assert the fenced ` ``` ` block output. Add one bold-run RTF case
(`NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)`).

**Verify**: `swift test --filter MarkdownConverterTests` → all pass.

## Test plan

Steps 1-2 are the test plan (≥ 12 new tests). Model file structure after
`NoteStoreTests.swift`.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0; `MarkdownConverterTests` exists with ≥ 12 tests
- [ ] `git status` shows only the new test file (plus the plans index)
- [ ] `plans/README.md` status row updated

## STOP conditions

- A fixture produces output that indicates real data corruption (e.g. list
  marker duplicated as `- •\tone`, heading text lost) — report as a bug, do
  not change the converter.
- Tests hang: the main-thread HTML-importer hop (`MarkdownConverter.swift:21`)
  deadlocks if a test calls it off the main thread inside a
  `DispatchQueue.main.sync` — keep test calls on the main thread (default for
  XCTest) and report if a hang persists anyway.

## Maintenance notes

- Plan 013 (restrict remote resource loading in HTML import) depends on this
  suite as its regression net — land this first.
- Reviewer: check assertions are substring-based where importer whitespace
  could vary, and that no test asserts an escaping behavior the converter
  deliberately doesn't have.
