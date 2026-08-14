# Plan 027: Make Edit ▸ Cut/Copy/Delete work on selected notes

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/AppDelegate.swift Sources/Nickel/Panel/NoteListTable.swift Sources/Nickel/Panel/FloatingPanel.swift`
> On any change, compare the "Current state" excerpts against live code; on a
> mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED (responder-chain shadowing; see STOP conditions)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

The Edit menu advertises Cut/Copy/Paste/Delete via `NSText` selectors, which
only field editors respond to. When the note list has focus with notes
selected, those items are permanently disabled even though ⌘C and ⌫ work via
the panel's own key handling. A menu-driven or VoiceOver user therefore
cannot copy or delete a note at all, and the menu misrepresents the app's
capabilities — a visible non-native tell. After this plan, Edit ▸ Copy/Delete
act on the note selection whenever the note list has focus, and Cut is
removed for notes (notes have no cut semantics here) while still working in
text fields.

## Current state

- `Sources/Nickel/AppDelegate.swift:227-235` builds the Edit menu:

```swift
editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
// No key equivalent: ⌫ already deletes via the panel/field's own key
// handling, so this exists for discoverability and menu-driven use
// (e.g. VoiceOver), not as the primary way to delete.
editMenu.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
```

  Nil-targeted, so they resolve through the responder chain. Field editors
  (search, composer, inline edit, header rename) respond to the `NSText`
  selectors; nothing else does.
- The note list's table view is `NoteListTableView` in
  `Sources/Nickel/Panel/NoteListTable.swift` (~line 952 onward). It is the
  panel's resting first responder and already overrides `selectAll(_:)` — the
  pattern to follow. It holds `weak var coordinator: NoteListCoordinator?`;
  the coordinator holds `actions: PanelActions!` and `selection:
  SelectionModel!` (private — you will need to expose minimal access, see
  Step 1).
- `Sources/Nickel/Panel/PanelActions.swift` — the actions to call:
  `copy(pasteboard:)` (line 54), `delete()` (line 158). Both already guard
  empty selections and the Logbook cases internally (`delete` routes Logbook
  deletes to a confirmation).
- `Sources/Nickel/Panel/FloatingPanel.swift:534-535` — exemplar of a
  responder-chain override on this stack:

```swift
override func selectAll(_ sender: Any?) {
    selectionModel.selectAllNotes()
}
```

  (Note: that one is on the PANEL; your new overrides go on the TABLE so
  field editors keep priority — the field editor is first responder while
  editing text, so text copy/paste is unaffected either way.)
- Menu validation convention: `AppDelegate` already conforms to
  `NSMenuItemValidation` (`validateMenuItem`, ~line 379) for "Move to
  Section…". For responder-chain items, the standard mechanism is
  `NSUserInterfaceValidations`/`validateUserInterfaceItem` on the responder
  that implements the action.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | 377 + new tests, 0 failures |
| Probe | `NICKEL_UI_PROBE=1 .build/debug/Nickel` | all checks passed |

## Scope

**In scope**:
- `Sources/Nickel/Panel/NoteListTable.swift` (the `NoteListTableView` class,
  plus minimal coordinator access if needed)
- `Sources/Nickel/AppDelegate.swift` (Edit menu wording only, per Step 3)
- `Tests/NickelTests/PanelActionsTests.swift` or a new test file

**Out of scope**:
- Paste: pasting into the list is not a feature; leave the Paste item as the
  `NSText` selector (correct for text fields, disabled otherwise).
- `FloatingPanel.keyDown` / `PanelShortcuts` — the ⌘C/⌫ key path is separate
  and already works; do not reroute it in this plan.
- Any new Edit-menu items (Find, Emoji) — separate plan (039).

## Git workflow

- Branch: `advisor/027-edit-menu-note-actions` from `main`
  (`git checkout -b advisor/027-edit-menu-note-actions main`).
- Imperative commit messages, body explains why.

## Steps

### Step 1: Implement the actions on `NoteListTableView`

Add to `NoteListTableView`:

```swift
@objc func copy(_ sender: Any?) { coordinator?.copySelection() }
@objc func delete(_ sender: Any?) { coordinator?.deleteSelection() }
```

and on `NoteListCoordinator` two thin funcs `copySelection()` /
`deleteSelection()` calling `actions?.copy()` / `actions?.delete()` (the
coordinator's `actions` is private; these wrappers keep it that way).

Conform `NoteListTableView` to `NSUserInterfaceValidations`:

```swift
func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(copy(_:)), #selector(delete(_:)):
        return coordinator?.hasSelectedNotes == true
    default:
        return responds(to: item.action)
    }
}
```

with `hasSelectedNotes` on the coordinator reading
`!(selection?.selectedIDs.isEmpty ?? true)`.

**Verify**: `swift build` → exit 0.

### Step 2: Point the menu at plain selectors

In `AppDelegate.swift`, change Copy to `#selector(NSText.copy(_:))` →
`Selector(("copy:"))`? — NO. Keep it simple and unambiguous: use
`#selector(NSText.copy(_:))` unchanged. `NSText.copy(_:)` produces the plain
`copy:` selector, which is the SAME selector your table override implements,
so the responder chain reaches the table when no field editor is active.
Same for `delete(_:)`. Verify this equivalence by printing
`NSStringFromSelector(#selector(NSText.copy(_:)))` in a scratch test if in
doubt — expected `"copy:"`. Therefore Step 2 requires NO change to the
Copy/Delete items' actions.

Remove the "Cut" item entirely (notes cannot be cut, and field editors still
get ⌘X through the key path without a menu item — WAIT: removing the menu
item removes ⌘X handling for text fields via menu. Instead KEEP Cut as is;
it stays enabled only for field editors, which is correct native behavior).
So: Step 2 is a no-op except adding a comment above the Copy/Delete items
noting they resolve to the note list when it has focus.

**Verify**: `swift build` → exit 0.

### Step 3: Tests

In `Tests/NickelTests/` add coverage driving the selectors (model on
`ComposerFocusTests`, which builds a real `FloatingPanel`): with two notes
selected, sending `copy(_:)` to the table view puts the notes' text on a
test pasteboard? — `PanelActions.copy()` uses `.general` by default and the
coordinator wrapper can't inject a pasteboard. Instead test at the seam:
assert `validateUserInterfaceItem` returns false with empty selection and
true with a selection, and assert `deleteSelection()` deletes the selected
note from the store. Name the file `NoteListMenuActionsTests.swift`.

**Verify**: `swift test` → all pass, count = 377 + new.

## Test plan

- `validateUserInterfaceItem`: empty selection → false; non-empty → true;
  unrelated selector falls through to `responds(to:)`.
- `deleteSelection()` removes the selected notes (live list).
- Delete in Logbook routes to the confirmation request (assert
  `selection.sectionDeleteConfirmation`-equivalent state; read how
  `PanelActionsTests` asserts `requestPermanentDelete` and mirror it).

## Done criteria

- [ ] `swift build` exits 0, no warnings
- [ ] `swift test` all pass; new tests present
- [ ] Manual (report for the human): with notes selected, Edit ▸ Copy and
      Edit ▸ Delete are enabled and act; with the search field focused,
      Edit ▸ Copy still copies text
- [ ] No files outside scope modified
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails.
- `NSStringFromSelector(#selector(NSText.copy(_:)))` is not `"copy:"` —
  the selector-identity assumption underlying Step 2 is false; report.
- Implementing `copy(_:)` on the table breaks text-field copy (menu item
  grabs the table implementation while a field editor is active). The field
  editor is ahead of the table in the responder chain, so this should be
  impossible — if observed, report, don't work around.
- ⌘C via the existing `keyDown` path stops working.

## Maintenance notes

- Any future note action added to the Edit menu must follow this pattern:
  selector on `NoteListTableView`, thin coordinator wrapper, validation via
  `validateUserInterfaceItem`.
- Reviewer: confirm no retain cycle was introduced (wrappers must not
  capture `actions` strongly outside the coordinator).
