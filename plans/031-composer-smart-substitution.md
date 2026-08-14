# Plan 031: Stop smart quotes/dashes from rewriting Markdown in the composer and inline edits

> **Executor instructions**: Follow this plan step by step, verifying each
> step. On any STOP condition, stop and report. Update this plan's row in
> `plans/README.md` when done — unless a reviewer told you they maintain the
> index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/Panel/FloatingPanel.swift Sources/Nickel/Panel/NoteRow.swift Sources/Nickel/Panel/NoteSourceTextView.swift`
> On change, compare excerpts; mismatch = STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

Nickel preserves captured/typed formatting as Markdown. The standalone note
editor window already disables automatic quote/dash/text substitution, with a
doc comment explaining that substitution silently rewrites Markdown source
(`"` → `"`, `--` → `–`) as it's typed. But the composer (the app's primary
input surface), the inline note editor, and any other panel text field do
NOT disable it, so the same Markdown typed there is corrupted at the point
of entry when the system's "smart quotes and dashes" setting is on (the
default). After this plan, every text surface that produces note content
matches the editor window's behavior.

## Current state

- The exemplar, `Sources/Nickel/Panel/NoteSourceTextView.swift:40-42`:

```swift
textView.isAutomaticQuoteSubstitutionEnabled = false
textView.isAutomaticDashSubstitutionEnabled = false
textView.isAutomaticTextReplacementEnabled = false
```

  (with the rationale doc comment at `:10-12`).
- The panel's shared field editor — used by every `GrowingTextField` in the
  panel window (composer; check which other fields are `GrowingTextField`) —
  `Sources/Nickel/Panel/FloatingPanel.swift:183-196`:

```swift
private final class DragRejectingFieldEditor: NSTextView {
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
}

private lazy var dragRejectingFieldEditor: DragRejectingFieldEditor = {
    let editor = DragRejectingFieldEditor()
    editor.isFieldEditor = true
    return editor
}()

func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    guard client is GrowingTextField else { return nil }
    return dragRejectingFieldEditor
}
```

  Note the guard: only `GrowingTextField` clients get the custom editor;
  other fields (e.g. the search field) use the window's default field
  editor. Search input never becomes note content, so it is OUT of scope.
- The inline note editor: `Sources/Nickel/Panel/NoteRow.swift` —
  `InlineNoteEditorField` / `InlineNoteTextView` (`makeNSView` around
  `NoteRow.swift:355-404`). Determine whether it is an `NSTextView` directly
  (then set the three flags in `makeNSView`) or a field-editor client
  (then it's covered by the field editor change). Read the code; do not
  guess.
- The section-header rename field and composer: identify each panel text
  input (`grep -n "GrowingTextField\|NSTextField\|NSTextView" Sources/Nickel/Panel/*.swift`)
  and classify: produces note/section content (needs the flags) vs search
  (excluded).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | 377 pass |

## Scope

**In scope**:
- `Sources/Nickel/Panel/FloatingPanel.swift` (field editor configuration)
- `Sources/Nickel/Panel/NoteRow.swift` (inline editor, if it's a raw
  `NSTextView`)

**Out of scope**:
- `NoteSourceTextView.swift` (already correct).
- The search field — substitution there is harmless and native.
- Spellchecking flags (`isContinuousSpellCheckingEnabled` etc.) — leave at
  system defaults; this plan is only the three substitution flags.

## Git workflow

- Branch: `advisor/031-composer-smart-substitution` from `main`
  (`git checkout -b advisor/031-composer-smart-substitution main`).

## Steps

### Step 1: Field editor flags

In `dragRejectingFieldEditor`'s initializer closure, set the same three
flags as `NoteSourceTextView.swift:40-42`, with a short comment referencing
the same rationale ("Markdown source; see NoteSourceTextView"). Rename the
class? No — keep `DragRejectingFieldEditor` (its doc comment gains one line
about substitution).

**Verify**: `swift build` → exit 0.

### Step 2: Inline editor flags

If `InlineNoteTextView` is a raw `NSTextView` (not a field-editor client),
set the three flags in its `makeNSView`. If it IS a field-editor client,
confirm by reading `windowWillReturnFieldEditor`'s guard whether it's a
`GrowingTextField` — if it isn't covered, extend coverage the cleanest way
(setting flags at the editor's own creation beats widening the field-editor
guard).

**Verify**: `swift build` → exit 0; `swift test` → 377 pass.

### Step 3: Manual verification note

You cannot verify substitution headlessly (it depends on the system
setting). In your report, state exactly what the human should do: System
Settings ▸ Keyboard ▸ "Use smart quotes and dashes" ON, then type `--` and
`"x"` into (a) the composer, (b) an inline note edit, (c) the editor
window; all three must keep the literal characters.

## Test plan

No new XCTests — the flags aren't meaningfully unit-testable (they're
NSTextView state, assertable but trivially so). If an existing test file
constructs the field editor, add flag assertions there; otherwise skip.

## Done criteria

- [ ] `swift build` exit 0, no warnings
- [ ] `swift test` 377 pass
- [ ] `grep -n "isAutomaticQuoteSubstitutionEnabled" Sources/Nickel/Panel/FloatingPanel.swift` → hit
- [ ] Inline editor covered (grep it in `NoteRow.swift`, or the report
      explains why the field editor already covers it)
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails.
- The inline editor turns out to share text machinery with the composer in
  a way that makes the flags apply twice with different values — report.

## Maintenance notes

- Any NEW text input that produces note content must copy these flags; the
  reviewer checklist for new fields should include it.
- If a user ever asks FOR smart quotes in prose notes, this becomes a
  setting — don't preemptively add one.
