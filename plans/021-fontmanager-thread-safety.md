# Plan 021: Replace off-main-thread NSFontManager use with font-descriptor traits

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 83d0b46..HEAD -- Sources/Nickel/Support/MarkdownConverter.swift Tests/NickelTests/MarkdownConverterTests.swift`
> If either file changed since this plan was written, compare the excerpts
> below against the live code; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `83d0b46`, 2026-08-02

## Why this matters

`MarkdownConverter` walks captured rich text and asks
`NSFontManager.shared.traits(of:)` whether each run is bold/italic.
`NSFontManager` is an AppKit singleton that is not thread-safe, and this
code runs on a background queue: capture fires on
`DispatchQueue.global(qos: .userInitiated)` (see
`Sources/Nickel/AppDelegate.swift:86-87`), and `markdown(from:)` only hops
to the main thread for the HTML *parse*, not the attribute walk (the RTF
path never hops at all). The classic symptom is an intermittent crash or
garbage bold/italic markers on exactly the code path that runs on arbitrary
copied content. The thread-safe replacement —
`font.fontDescriptor.symbolicTraits` — is a pure value lookup and is
*already used three lines away* in the same file.

## Current state

`Sources/Nickel/Support/MarkdownConverter.swift`. SwiftPM, macOS 14+, XCTest.

Call site 1, inside `inlineMarkdown` (`MarkdownConverter.swift:219-232`):

```swift
var marked = core
let font = attributes[.font] as? NSFont
let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []

if isMonospaced(font) {
    marked = "`\(marked)`"
} else {
    if traits.contains(.italicFontMask) {
        marked = "*\(marked)*"
    }
    if traits.contains(.boldFontMask), !suppressBold {
        marked = "**\(marked)**"
    }
}
```

Call site 2, `headingLevel` (`MarkdownConverter.swift:258-268`):

```swift
private static func headingLevel(for font: NSFont?) -> Int? {
    guard let font else { return nil }
    let traits = NSFontManager.shared.traits(of: font)
    guard traits.contains(.boldFontMask) else { return nil }
    switch font.pointSize {
    case 20...: return 1
    ...
}
```

The in-repo exemplar of the correct API, `isMonospaced`
(`MarkdownConverter.swift:247-253`):

```swift
private static func isMonospaced(_ font: NSFont?) -> Bool {
    guard let font else { return false }
    if font.fontDescriptor.symbolicTraits.contains(.monoSpace) { return true }
    ...
}
```

Type note: `NSFontManager.traits(of:)` returns `NSFontTraitMask`
(`.boldFontMask` / `.italicFontMask`);
`fontDescriptor.symbolicTraits` returns `NSFontDescriptor.SymbolicTraits`
(`.bold` / `.italic`). They are different option sets — the member names
change with the API.

Regression net: `Tests/NickelTests/MarkdownConverterTests.swift` already
asserts bold (`**bold**`), italic (`*italic*`), headings (`# Title` from
`<h1>`, with no `**`), and code spans. These tests are the gate that the
swap preserves behavior.

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | exit 0, all pass    |

## Scope

**In scope**:
- `Sources/Nickel/Support/MarkdownConverter.swift` (the two `NSFontManager` call sites only)
- `Tests/NickelTests/MarkdownConverterTests.swift` (only if a new case is added; existing tests should not need edits)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- The sanitizer (`strippingRemoteResources`) — plan 022's territory.
- The main-thread hop in `markdown(fromHTML:)` — correct as-is for the parse.
- `isMonospaced`'s family-name fallback list.

## Git workflow

- Branch: `advisor/021-fontmanager-thread-safety`
- Commit style: short imperative subject, e.g. "Read font traits from the descriptor, not NSFontManager".
- Do NOT push or open a PR.

## Steps

### Step 1: Swap both call sites

In `inlineMarkdown`:

```swift
let traits = font?.fontDescriptor.symbolicTraits ?? []
...
if traits.contains(.italic) { ... }
if traits.contains(.bold), !suppressBold { ... }
```

In `headingLevel`:

```swift
let traits = font.fontDescriptor.symbolicTraits
guard traits.contains(.bold) else { return nil }
```

**Verify**: `swift build` → exit 0; then
`grep -n "NSFontManager" Sources/` → no matches.

### Step 2: Run the converter suite

**Verify**: `swift test --filter MarkdownConverterTests` → all pass
(bold/italic/heading/code-span assertions unchanged). Then `swift test` →
full suite passes.

### Step 3 (only if step 2 fails): investigate equivalence

If a bold or italic test fails, the descriptor traits for the specific font
AppKit's importer produced differ from the font-manager mask. Print the
failing run's font and both trait readings, and STOP — report the mismatch
rather than layering heuristics.

## Test plan

No new tests required — `MarkdownConverterTests` already pins the observable
behavior (bold, italic, heading, monospace). Optionally add
`testHTMLBoldItalicCombination` (`<b><i>x</i></b>` → `***x***` or the
current observed nesting) if not present, to widen the net.

## Done criteria

- [ ] `swift build` exits 0
- [ ] `grep -rn "NSFontManager" Sources/` → no matches
- [ ] `swift test` exits 0, all pass
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- The call sites don't match the excerpts.
- Any `MarkdownConverterTests` case fails after the swap (see step 3 —
  report, don't patch around).

## Maintenance notes

- This closes the last AppKit-singleton use on the capture background path.
  Reviewer: sanity-check there's no other main-thread-only AppKit API in
  `markdown(from:)`'s walk (NSFont/NSFontDescriptor value reads are fine).
- If Swift 6 strict concurrency is adopted later (see plans/README.md
  rejected/deferred list), this change removes one of the diagnostics that
  migration would have surfaced.
