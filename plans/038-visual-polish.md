# Plan 038: Visual polish — adaptive overlay dim, scrollable ⌘/ card, search focus ring, Reduce Motion, Settings casing

> **Executor instructions**: Follow this plan step by step, verifying each
> step. On any STOP condition, stop and report. Update this plan's row in
> `plans/README.md` when done — unless a reviewer told you they maintain the
> index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/Panel/ShortcutsOverlay.swift Sources/Nickel/Panel/SectionSwitcher.swift Sources/Nickel/Panel/PanelView.swift Sources/Nickel/Panel/FloatingPanel.swift Sources/Nickel/Support/SettingsView.swift`
> Other plans touching these files is expected — verify each excerpt below
> still exists at its symbol before editing; a missing mechanism = STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/029-dynamic-hotkey-copy.md (soft — both edit
  ShortcutsOverlay; land 029 first to avoid conflicts)
- **Category**: bug (visual/accessibility polish)
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

Five smaller substandard-vs-native items, bundled because each is S and they
share files: (1) the modal scrim behind the ⌘K palette and ⌘/ card is
hardcoded `Color.black.opacity(0.15)`, nearly invisible in dark mode, so the
overlays lose their "everything behind is inert" cue; (2) the ⌘/ card is a
fixed stack that overflows and clips at the panel's default 560pt height —
the reference card can't be fully read; (3) the search capsule suppresses
the system focus ring and substitutes nothing, so ⌘F gives no visible focus
(the composer already draws a substitute ring — the convention exists);
(4) Reduce Motion is ignored by the panel slide, the note-row spring, and
overlay transitions; (5) the Settings window mixes Title Case and sentence
case toggles in one group.

## Current state

- Scrims: `Sources/Nickel/Panel/ShortcutsOverlay.swift:20` and
  `Sources/Nickel/Panel/SectionSwitcher.swift:61`, both:

```swift
Color.black.opacity(0.15)
    .contentShape(Rectangle())
    .onTapGesture { dismiss() }
```

- Error banner: `Sources/Nickel/Panel/PanelView.swift:850`
  `.fill(Color.orange.opacity(0.2))` — non-semantic; swap to
  `Color(nsColor: .systemOrange).opacity(0.2)` while there (one-liner).
- ⌘/ card: `ShortcutsOverlay.swift:32-73` — `VStack` of 4 groups/22 rows,
  `padding(.top, 48)`, no ScrollView, no max height. Panel default height
  560 (`FloatingPanel.swift:38`).
- Search focus: `Sources/Nickel/Panel/SearchField.swift` sets
  `focusRingType = .none`; the composer's substitute-ring convention is at
  `PanelView.swift:574-590` (dashed `strokeBorder(Color.accentColor …)`
  driven by `selection.isComposerFocused`). The search capsule is built at
  `PanelView.swift:302-323`. Focus state source: check how
  `isComposerFocused` is derived (`FloatingPanel.syncComposerFocus`) and
  whether an equivalent `isSearchFocused` exists — if not, derive the ring
  from first-responder the same way (`grep -n "isSearchFocused\|syncComposerFocus" Sources/Nickel -r`).
- Animations: `PanelView.swift:1217` (`noteRowSpring`), `:1222`
  (`panelOverlay`), `FloatingPanel.swift:341-362` (the 0.18s slide via
  `toggleAnimationDuration`). Reduce Motion signal:
  `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (+
  `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` for live
  changes).
- Settings casing: `Sources/Nickel/Support/SettingsView.swift:22-40` —
  "Launch at Login", "Keep Panel on Top", "Show Menu Bar Icon" (Title
  Case) vs "Mark notes as done when copied" (sentence case). macOS System
  Settings uses sentence case for toggle labels; the repo's UI-copy rule
  prefers plain outcome language. Convert the three Title Case labels to
  sentence case: "Launch at login", "Keep panel on top", "Show menu bar
  icon". Pickers "Capture" / "Show/Hide Panel" → "Show/hide panel".

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | all pass |
| Probe | `NICKEL_UI_PROBE=1 .build/debug/Nickel` | all checks passed |

## Scope

**In scope**: the five files above at the cited sites; a tiny shared
`ReduceMotion` helper if needed.

**Out of scope**:
- Swapping SearchField to `NSSearchField` (deferred; recorded in README
  index as rejected-for-now).
- The drag/drop or reveal animations (AppKit-side, already minimal).
- Any layout redesign of the ⌘/ card content.

## Git workflow

- Branch: `advisor/038-visual-polish` from `main`
  (`git checkout -b advisor/038-visual-polish main`).

## Steps

### Step 1: Adaptive scrim

Replace both `Color.black.opacity(0.15)` with a shared
`Color.overlayScrim` defined once (e.g. in a small extension near
`PanelView`'s animation extension):
`Color(nsColor: .black).opacity(0.15)` for light, `0.35` for dark —
implement via `@Environment(\.colorScheme)` at the two use sites or a
computed style; keep the tap-to-dismiss modifiers unchanged. (No material
change; just a legible dim in both appearances.)

**Verify**: `swift build` → exit 0.

### Step 2: Scrollable ⌘/ card

Wrap the card's group stack in a `ScrollView` whose height caps at
`geometry.size.height - 96` (the overlay already sits in a
`GeometryReader`). The card keeps its intrinsic height when it fits;
scrolls when it doesn't. Verify no scroll indicators flash when content
fits (`.scrollIndicators(.automatic)`).

**Verify**: `swift build`; probe still green.

### Step 3: Search focus ring

Mirror the composer's substitute-ring: derive `isSearchFocused` from the
same first-responder sync that feeds `isComposerFocused` (read
`FloatingPanel.syncComposerFocus`; extend it to also publish search focus
on `SelectionModel` following the exact same pattern and naming), then
overlay the capsule with the same dashed accent `strokeBorder` used at
`PanelView.swift:588`, shown when focused. Keep line width/dash identical
to the composer's for consistency.

**Verify**: `swift build`; `swift test` (the focus sync has tests —
`ComposerFocusTests`; extend with a search-focus case following its
structure).

### Step 4: Reduce Motion

Add a helper:

```swift
enum Motion {
    static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
```

Gate: `PanelView.noteRowSpring` and `.panelOverlay` → when reduced, use
`.linear(duration: 0)` (or `nil` animation); `FloatingPanel.toggle()`'s
slide → duration 0 when reduced (keep the fade if trivial, else instant).
Read each animation call site and apply the gate at the DEFINITION
(`noteRowSpring`/`panelOverlay` computed vars) so call sites don't change.
Live setting changes: acceptable to read at animation time (computed var),
which handles changes automatically — note this in a comment.

**Verify**: `swift build`; probe green (probe doesn't assert motion).

### Step 5: Settings casing + banner color

Apply the sentence-case labels listed in Current state and the
`systemOrange` swap.

**Verify**: `swift build`; `swift test` all pass.

## Test plan

- Extend `ComposerFocusTests` with the search-focus ring state case.
- Everything else: probe + build gates; manual pass for the human: dark
  mode ⌘K scrim visible; ⌘/ card scrolls at default size; ⌘F shows a ring;
  System Settings Reduce Motion on → panel toggle/row changes are instant;
  Settings window reads consistently.

## Done criteria

- [ ] `swift build` exit 0, no warnings
- [ ] `swift test` all pass incl. new focus test
- [ ] Probe all pass
- [ ] `grep -rn "Color.black.opacity(0.15)" Sources/` → no matches
- [ ] `grep -n "Launch at Login" Sources/Nickel/Support/SettingsView.swift` → no matches
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails (symbol-level).
- Extending `syncComposerFocus` to search requires touching the focus
  authority in a way its comments warn against — report with the comment
  text.
- The ⌘/ ScrollView breaks the card's tap-outside-to-dismiss hit area.

## Maintenance notes

- New overlays must use `Color.overlayScrim` and respect `Motion.isReduced`.
- Reviewer: check dark-mode appearance of the scrim over both wallpaper
  extremes; check the ring perfectly hugs the capsule (no 1pt gap).
