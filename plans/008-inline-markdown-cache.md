# Plan 008: Memoize inline Markdown parsing for expanded note blocks

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 3343e77..HEAD -- Sources/Nickel/Panel/MarkdownBlocksView.swift`
> On any change, re-verify the excerpts; on a mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `3343e77`, 2026-08-02

## Why this matters

Note rows are deliberately eager `VStack` children, so every store mutation
re-evaluates every visible row's `body`. `MarkdownCache` was added for
exactly that reason — but it only covers block splitting and the collapsed
3-line preview. The *expanded* path still calls
`AttributedString(markdown:options:)` fresh, per block, per re-render
(`MarkdownBlocksView.inline(_:)`), which is the exact cost the cache was
built to avoid. This plan closes the gap with the same pattern.

## Current state

- `Sources/Nickel/Panel/MarkdownBlocksView.swift`:
  - `MarkdownCache` (lines 115-165) — existing memoization enum: private
    `AttributedStringBox` class wrapper (lines 121-124, `NSCache` needs
    class values), two `NSCache<NSString, …>` statics with
    `countLimit = 500` (lines 128-138), and cached accessors
    `blocks(for:)` / `collapsedPreview(for:)`. The header comment
    (lines 106-114) explains the eager-VStack rationale and the
    text-as-key eviction story.
  - The uncached hole, `inline(_:)` (lines 242-245), called from every
    non-code branch of `blockView(_:)`:

```swift
private func inline(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}
```

## Commands you will need

| Purpose | Command      | Expected on success |
|---------|--------------|---------------------|
| Build   | `swift build`| exit 0              |
| Tests   | `swift test` | all pass            |

## Scope

**In scope**:
- `Sources/Nickel/Panel/MarkdownBlocksView.swift`

**Out of scope**:
- `NoteRow.swift` (its collapsed path already uses `collapsedPreview`).
- Changing cache limits or the existing two caches.
- Reintroducing `LazyVStack` anywhere — settled decision, do not touch.

## Git workflow

- Branch: `advisor/008-inline-markdown-cache`
- One commit, imperative message (e.g. "Cache inline Markdown parses for expanded blocks").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add `MarkdownCache.inline(for:)`

In the `MarkdownCache` enum, add a third `NSCache<NSString, AttributedStringBox>`
static (`countLimit = 500`, matching the others — expanded notes have
multiple blocks each, but 500 block-strings is still ample for visible rows)
and:

```swift
/// The inline-parsed `AttributedString` for one block's text, used by
/// `MarkdownBlocksView.blockView`. Same rationale as the caches above.
static func inline(for text: String) -> AttributedString {
    let key = text as NSString
    if let box = inlineCache.object(forKey: key) { return box.value }
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    let attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    inlineCache.setObject(AttributedStringBox(attributed), forKey: key)
    return attributed
}
```

### Step 2: Route `MarkdownBlocksView.inline(_:)` through it

Replace the body of the private `inline(_:)` method with
`MarkdownCache.inline(for: text)` (keep the method as the view's seam so
call sites don't change).

**Verify**: `swift build` → exit 0, then `swift test` → all pass.

### Step 3: Confirm no other raw parse sites remain in this file

**Verify**: `grep -n "AttributedString(markdown:" Sources/Nickel/Panel/MarkdownBlocksView.swift`
→ exactly 2 matches, both inside `MarkdownCache` (`collapsedPreview` and the
new `inline(for:)`).

## Test plan

No new tests — rendering-layer memoization with identity semantics unchanged
(same input → same output; cache is keyed by exact text, evicts under memory
pressure like the existing two). The suite must stay green.

## Done criteria

- [ ] `swift build` exits 0; `swift test` all pass
- [ ] Step 3 grep shows exactly 2 matches, both in `MarkdownCache`
- [ ] `git status` shows only `MarkdownBlocksView.swift` modified (plus plans index)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `MarkdownCache` or `inline(_:)` no longer matches the excerpts.
- You find yourself wanting to change `blockView`'s structure — out of scope.

## Maintenance notes

- If per-block styling ever becomes context-dependent (e.g. different parse
  options per note), the text-only cache key breaks — the key must then
  include the option set.
- Reviewer: verify the new cache uses the existing `AttributedStringBox`
  (no duplicate box type).
