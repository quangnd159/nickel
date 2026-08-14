# Plan 039: One source of truth for window shortcuts and menus; File menu; direct overlay calls

> **Executor instructions**: Follow this plan step by step, verifying each
> step. On any STOP condition, stop and report. Update this plan's row in
> `plans/README.md` when done — unless a reviewer told you they maintain the
> index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/Panel/PanelShortcuts.swift Sources/Nickel/Panel/FloatingPanel.swift Sources/Nickel/AppDelegate.swift Sources/Nickel/Panel/ShortcutsOverlay.swift Sources/Nickel/Panel/SectionSwitcher.swift Sources/Nickel/Panel/NoteContextMenu.swift Sources/Nickel/Panel/SectionHeader.swift Sources/Nickel/Panel/PanelView.swift`
> Plans 026–038 touching these files is expected; verify each excerpt at its
> symbol; a missing mechanism = STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/027-edit-menu-note-actions.md,
  plans/029-dynamic-hotkey-copy.md, plans/032-modern-activation.md (all
  touch the same files; land them first)
- **Category**: tech-debt
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

`PanelShortcuts` exists to be "the one table" for shortcuts, but the whole
class of window/navigation shortcuts (⌘K, ⌃⌘M, ⌘/, ⌘F, ⌘N, ⌘W, ⌘,, ⇧⌘],
⇧⌘[, ⇧⌘R) never joined it: they're matched as raw literals in
`FloatingPanel.performKeyEquivalent`, re-declared as menu key equivalents in
`AppDelegate`, hand-written as display strings in `ShortcutsOverlay`, and
decoratively repeated in the ⋯ menu. They have ALREADY drifted ("Move to
Section" vs "Move to Section…"; "Keyboard shortcuts" vs "Keyboard
Shortcuts"). Adjacent debt in the same files: the status-item menu rebuilds
five app-menu items by hand (already divergent: different Settings key
equivalent); a dead duplicate of the section-header context menu has
drifted (`role: .destructive` missing in the dead copy); overlay toggles
round-trip through NotificationCenter from code that holds the model; and
the standard File menu (New Note ⌘N) and Edit ▸ Emoji & Symbols are
missing. One consolidation round.

## Current state

- `Sources/Nickel/Panel/PanelShortcuts.swift:4-27` — doc comment claiming
  full coverage; `PanelCommand` has 12 note-level cases only. Existing
  fields per `PanelShortcut`: match rule, `menuShortcut`
  (SwiftUI `KeyboardShortcut`), overlay display strings (read the struct
  before extending).
- `Sources/Nickel/Panel/FloatingPanel.swift` `performKeyEquivalent`
  (~:413-466): ten literal `if modifiers == […], characters == "…"` blocks
  (⌘K, ⌃⌘M, ⌘/, ⌘F, ⌘N, ⌘W, ⌘,, ⇧⌘], ⇧⌘[, ⇧⌘R — the bracket pair also
  keyCode-matches 30/33 as a layout fallback; preserve that).
- `Sources/Nickel/AppDelegate.swift:145-334` — `setupMainMenu()`: App /
  Edit / View / Window / Help; View menu items re-declare ⌘K/⌃⌘M/⇧⌘]/⇧⌘[
  equivalents (~:250-291); no File menu; Edit menu has no Find or Emoji &
  Symbols items. `makeMenu()` (~:388-455) — the status-item menu —
  hand-rebuilds About / Check for Updates… / Reveal Notes in Finder /
  Settings… / Quit (Settings with `keyEquivalent: ""` vs the app menu's
  `","`).
- `Sources/Nickel/Panel/ShortcutsOverlay.swift:42-57` — hand-listed
  Navigate rows for the ten window shortcuts.
- Notifications: `.nickelToggleSectionSwitcher` / `.nickelToggleMoveToSection`
  (declared in `SectionSwitcher.swift`), `.nickelToggleShortcuts` — posted
  from `FloatingPanel.performKeyEquivalent` and `AppDelegate`, received in
  `PanelView.swift:195-203` which flips `selection.presentedOverlay`.
  `FloatingPanel` writes `selectionModel.presentedOverlay` DIRECTLY in two
  other places (sendEvent ~:565-571; ⇧⌘R ~:461-466) — two mechanisms, one
  state. `AppDelegate` has `panel?.currentSelectionModel` access already
  (used by `validateMenuItem`).
- Dead code: `Sources/Nickel/Panel/NoteContextMenu.swift:83-108`
  `sectionHeaderMenu(...)` — zero call sites
  (`grep -rn "sectionHeaderMenu" Sources/` → definition only); the LIVE
  header menu is SwiftUI in `SectionHeader.swift:37-65` and has
  `role: .destructive` on Delete Section, which the dead copy lacks.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | all pass |
| Probe | `NICKEL_UI_PROBE=1 .build/debug/Nickel` | all checks passed |

## Scope

**In scope**: the eight drift-checked files; `Tests/NickelTests/PanelShortcutsTests.swift`.

**Out of scope**:
- The note-level 12 commands' matching (unchanged).
- Edit ▸ Find SUBMENU machinery — add a single "Find" item (⌘F) directly in
  Edit; a full Find submenu (Find Next etc.) has no backing features.
- Any new features; this is consolidation + the File menu + Emoji item.

## Git workflow

- Branch: `advisor/039-menu-shortcut-consolidation` from `main`
  (`git checkout -b advisor/039-menu-shortcut-consolidation main`).

## Steps

### Step 1: Extend the table

Add a parallel enum `WindowCommand: CaseIterable` in `PanelShortcuts.swift`
(cleaner than overloading `PanelCommand`, whose cases flow through
`FloatingPanel.handle`'s keyDown dispatch): cases `sectionSwitcher`,
`moveToSection`, `shortcutsCard`, `findFocus`, `newNote`, `closePanel`,
`settings`, `nextSection`, `previousSection`, `renameSection`. Each entry
carries: match rule (modifiers + character, plus the keyCode fallback for
the bracket pair), menu title (with HIG ellipsis where applicable), menu
`keyEquivalent` + modifier mask, and overlay display strings. Give it a
`static func command(for event: NSEvent) -> WindowCommand?` mirroring
`PanelShortcuts.command(for:)`. Update the file-top doc comment to describe
BOTH tables and their split (keyDown-dispatched note commands vs
performKeyEquivalent window commands).

**Verify**: `swift build` → exit 0.

### Step 2: Route the three consumers through it

- `FloatingPanel.performKeyEquivalent`: replace the ten literal blocks with
  one `switch WindowCommand.command(for: event)`; each case performs the
  existing action VERBATIM (post/notification or direct call — Step 4
  changes the mechanism, not this step; keep steps separable).
- `AppDelegate` View menu items: build titles/equivalents from the table
  entries.
- `ShortcutsOverlay` Navigate group: render from
  `WindowCommand.allCases`' overlay strings.

**Verify**: `swift build`; `swift test`; probe. Extend
`PanelShortcutsTests` with: every `WindowCommand` has non-empty title +
overlay strings; menu equivalent and match rule agree on key/modifiers
(mirror the existing agreement test's structure); titles that open a
further UI end in "…" (palette, settings, rename).

### Step 3: File menu, Find, Emoji & Symbols

In `setupMainMenu()`:
- Insert a File menu after the app menu: "New Note" (⌘N, from the table;
  `showPanelIfHidden()` + the same action ⌘N performs today — read what
  the `.nickelFocusComposer` path does and reuse it) and "Close" (⌘W,
  standard `performClose(_:)`? NO — the panel's ⌘W is a custom toggle;
  route to the same `showPanelIfHidden`-less panel-hide the table's
  `closePanel` entry performs; title "Close" per HIG).
- Edit menu: append "Emoji & Symbols" via the standard
  `orderFrontCharacterPalette(_:)` selector, nil target, no key equivalent
  (the system supplies fn/🌐), after a separator. Add "Find" (⌘F) — View
  or Edit? Edit per HIG for a Find item; nil-targeted custom selector on
  the panel following plan 027's pattern, or the same
  `showPanelIfHidden()` + focus-search post the View items use — match the
  existing View-item wiring style in AppDelegate.
- MOVE ⌘N/⌘F menu presence: since `performKeyEquivalent` intercepts while
  the panel is key, menu items are the discoverable/VoiceOver path (same
  pattern as existing View items). Verify no double-fire: panel key →
  intercepted; panel closed → menu fires and `showPanelIfHidden()` runs.

**Verify**: `swift build`; manual note in report (menu-driven ⌘N/⌘F with
panel hidden).

### Step 4: Direct overlay calls + status menu dedupe + dead code

- Move `toggleSectionSwitcher()`/`toggleMoveToSection()`/`toggleOverlay(.shortcuts)`
  logic from `PanelView` onto `SelectionModel` (they mutate only
  `presentedOverlay` + animation; `PanelView.swift:262-295`). `PanelView`'s
  `.onReceive` handlers call the model methods; `FloatingPanel` and
  `AppDelegate` call them DIRECTLY (`selectionModel.…` /
  `panel?.currentSelectionModel.…` after `showPanelIfHidden()`), and the
  three `.nickelToggle*` notification names + posts + receivers are
  deleted. KEEP the notifications ONLY if a receiver outside
  PanelView exists (`grep -rn "nickelToggleSectionSwitcher\|nickelToggleMoveToSection\|nickelToggleShortcuts" Sources/` first; if other receivers exist, STOP and report).
- Status-item menu: extract `private func appMenuCoreItems() -> [NSMenuItem]`
  building About / Check for Updates… / Reveal Notes in Finder / Settings…
  (⌘, equivalent consistently) / Quit, and compose BOTH `setupMainMenu()`'s
  app menu and `makeMenu()` from it (fresh instances per call — NSMenuItem
  can't be in two menus; the builder returns new items each call).
- Delete `NoteContextMenu.sectionHeaderMenu` (dead, drifted).

**Verify**: `swift build`; `swift test`; probe;
`grep -rn "sectionHeaderMenu" Sources/` → no matches;
`grep -rn "nickelToggleSectionSwitcher" Sources/` → no matches (or
reported exception).

## Test plan

- Extended `PanelShortcutsTests` (Step 2).
- Existing menu-hint consistency tests keep passing.
- Manual for the human: every shortcut in the ⌘/ card fires; View/File
  menu items work with the panel hidden; status-item menu matches the app
  menu; ⌘K/⌃⌘M/⌘/ open their overlays; section-header right-click still
  shows the destructive Delete.

## Done criteria

- [ ] `swift build` exit 0, no warnings; `swift test` all pass; probe passes
- [ ] `grep -n "characters == " Sources/Nickel/Panel/FloatingPanel.swift`
      → no window-shortcut literals remain (attachment-⌘V handling may
      remain; check context)
- [ ] File menu exists with New Note/Close; Edit has Emoji & Symbols and Find
- [ ] Status menu built from the shared builder
- [ ] Dead `sectionHeaderMenu` gone; overlay notifications gone
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails at symbol level.
- Another receiver of the overlay notifications exists.
- Menu-driven ⌘N/⌘F double-fires with the panel key (the interception
  assumption is false) — report which path double-ran.
- `WindowCommand` turns out to need per-platform key handling the current
  literals hide (e.g. the bracket keyCode fallback breaks) — report.

## Maintenance notes

- New window shortcuts go in `WindowCommand` — matching, menu, and overlay
  all follow; PanelShortcutsTests enforce agreement.
- Reviewer: check every deleted notification had exactly one receiver;
  check the status menu and app menu render identical titles.
