# Plan 034: Measure the edited row with inert content, not a second live editor

> **Executor instructions**: Follow this plan step by step, verifying each
> step. On any STOP condition, stop and report. Update this plan's row in
> `plans/README.md` when done — unless a reviewer told you they maintain the
> index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/Panel/NoteListTable.swift Sources/Nickel/Panel/NoteRow.swift Sources/Nickel/Support/UIProbe.swift`
> On change, compare excerpts; mismatch = STOP.
> Also: if plan 028 landed first, `invalidateAllRowHeights` will differ from
> this plan's assumptions in a compatible way (stale-marking instead of
> wipe); that is NOT a stop condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none (mergeable before or after 028/035/036)
- **Category**: bug
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

To compute a stale row's height, the coordinator hosts a full copy of the
row's SwiftUI content in an offscreen measuring view. For the note being
inline-edited, that copy includes a second LIVE `InlineNoteEditorField`,
whose `makeNSView` builds a real `NSTextView`, installs a delegate, and
schedules `view.window?.makeFirstResponder(view)`. Today this is safe only
by accident: the measuring view is never in a window (so the focus claim
no-ops) and the duplicate's delegate writes are never triggered. A future
change to how the editor seeds text or claims focus could turn a routine
height measurement into "the user's in-progress edit gets committed or
hijacked". It also builds a full text stack on every stale measurement of
the edited row. This plan substitutes inert content of identical geometry
for measurement, making the safety structural.

## Current state

- `Sources/Nickel/Panel/NoteListTable.swift:366-418` —
  `measureOutstandingRowHeights()`. Key excerpt (the stale branch):

```swift
// A stale row is measured from scratch, never from its cell: ...
measuringHost.rootView = AnyView(
    content(for: item, at: index).frame(width: width, alignment: .leading)
)
measuringHost.setFrameSize(NSSize(width: width, height: 0))
measuringHost.layoutSubtreeIfNeeded()
measured = max(measuringHost.idealHeight, 1)
```

  and the closing comment admitting the hazard:

```swift
// Leaves nothing hosted: the measuring view builds a real copy of a
// row's content, and for the row being edited that would include a
// second editor. It's never in a window — `InlineNoteEditorField`
// claims first responder through `view.window` — so it can't steal
// focus, but there's no reason to keep it alive either.
```

- `content(for:at:)` (same file, ~line 914-944) builds `NoteRowContent` /
  `LogbookRowContent` / headers. `NoteRowContent`
  (`Sources/Nickel/Panel/NoteRow.swift`) internally branches on
  `selection.editingID == noteID` to show either display text or
  `InlineNoteEditorField` (struct at `NoteRow.swift:329`;
  `makeNSView` at `:355-404` sets `isRichText=false`, zero
  `textContainerInset`, and the focus claim; `sizeThatFits` at `:422`
  computes height from the text layout at the proposed width; the editor
  uses the same font metrics as display + `lineSpacing(2)` — read
  `NoteRowContent`'s editor branch and `sizeThatFits` to confirm the exact
  metrics before writing the inert twin).
- The geometry gate: `Sources/Nickel/Support/UIProbe.swift:469`
  (`checkTallEditReveal`) asserts the cached height for an edited tall note
  matches the live cell's ideal height — this is the check that catches any
  divergence between the inert measurement and the real editor.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | 377 pass |
| Probe | `NICKEL_UI_PROBE=1 .build/debug/Nickel` | all checks passed (esp. tall-edit checks) |

## Scope

**In scope**:
- `Sources/Nickel/Panel/NoteListTable.swift` (measurement path)
- `Sources/Nickel/Panel/NoteRow.swift` (a measurement-only content variant
  or an `isForMeasurement` environment flag)
- `Sources/Nickel/Support/UIProbe.swift` (assertions if needed)

**Out of scope**:
- The live editor's behavior (focus, commit, delegate) — zero changes.
- The cell-reported (non-stale) measurement branch.
- `LogbookRowContent` (has no editor).

## Git workflow

- Branch: `advisor/034-inert-measurement-content` from `main`
  (`git checkout -b advisor/034-inert-measurement-content main`).

## Steps

### Step 1: Choose and implement the inert variant

Preferred design: an environment key, e.g.

```swift
private struct IsMeasurementOnlyKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var isMeasurementOnly: Bool { ... } }
```

`NoteRowContent`'s editor branch, when `isMeasurementOnly` is true, renders
an inert `Text(selection.editingText)` styled to the editor's EXACT
geometry: same font, `lineSpacing(2)` (confirm against the editor's
metrics), same insets/padding as `InlineNoteEditorField` produces (the
editor has `textContainerInset = .zero` — confirm what horizontal padding
the SwiftUI wrapper adds and mirror it), `frame(maxWidth: .infinity,
alignment: .leading)` + `fixedSize(horizontal: false, vertical: true)`.
A trailing-newline caveat: `NSTextView` reserves a line for a trailing
newline; `Text` does not. If `editingText` ends in "\n", append a space
to the inert text ("\n " ) so the heights match — verify via the probe's
tall-edit check and the mid-edit typing check.

The measuring call site then wraps content:
`content(for: item, at: index).environment(\.isMeasurementOnly, true)`.

**Verify**: `swift build` → exit 0.

### Step 2: Probe verification (the real gate)

Run the probe. `checkTallEditReveal` and `checkCachedHeightsMatchCells`
must pass — they compare the inert measurement against the LIVE editor
cell's layout. Additionally extend the mid-edit typing check (find the
insertText-driven check) to also type a trailing newline and re-assert the
cached height matches the cell.

**Verify**: `NICKEL_UI_PROBE=1 .build/debug/Nickel` → all checks passed.

### Step 3: Tighten the closing comment

Rewrite the "Leaves nothing hosted" comment: the measuring host now never
builds an editor at all; keep the reset-to-EmptyView (still good hygiene).

**Verify**: `swift build` → exit 0; `swift test` → 377 pass.

## Test plan

The probe is the test (geometry). No new XCTests. All 377 stay green.

## Done criteria

- [ ] `swift build` exit 0, no warnings
- [ ] `swift test` 377 pass
- [ ] Probe passes, incl. tall-edit + trailing-newline height parity
- [ ] Reading the diff confirms the measuring path can no longer construct
      `InlineNoteEditorField`
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails.
- The inert twin cannot be made to match the editor's height within 0.5pt
  in the probe after the trailing-newline fix and two styling iterations —
  report the residual delta and which text shapes diverge; do NOT ship an
  approximate measurement.
- The editor branch turns out to add dynamic chrome (e.g. attachment
  editing UI) whose height the twin can't reproduce — report.

## Maintenance notes

- Any future change to the editor's font, line spacing, insets, or padding
  MUST update the inert twin; the probe's parity checks are the tripwire —
  keep them in CI (plan 041 adds the probe to CI).
- Reviewer: scrutinize the twin's styling against `sizeThatFits` in
  `NoteRow.swift` line by line.
