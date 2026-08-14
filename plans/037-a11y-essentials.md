# Plan 037: Close the VoiceOver gaps and honor the system scroll-bar preference

> **Executor instructions**: Follow this plan step by step, verifying each
> step. On any STOP condition, stop and report. Update this plan's row in
> `plans/README.md` when done — unless a reviewer told you they maintain the
> index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/Panel/CaptureHUD.swift Sources/Nickel/Panel/PanelView.swift Sources/Nickel/AppDelegate.swift Sources/Nickel/Panel/SectionHeader.swift Sources/Nickel/Panel/LogbookView.swift Sources/Nickel/Panel/NoteListTable.swift`
> On change, compare excerpts; mismatch = STOP. (Plans 026–036 touching
> `NoteListTable.swift` elsewhere is expected; only the `scrollerStyle` line
> matters here.)

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug (accessibility)
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

Four confirmed accessibility gaps: (1) the capture HUD — the ONLY feedback
for a capture, including the "No text selected" failure — is a mouse-inert,
never-key panel that posts no VoiceOver announcement, so a VoiceOver user
gets nothing at all; (2) the two most important icon-only controls (⋯ menu,
paperclip) and the status-bar item are unlabeled and tooltip-less; (3)
section and Logbook day headers are uppercased display text without a
header trait or original-casing label, so the VoiceOver rotor can't
navigate by section and short names may be spelled letter-by-letter; (4)
the list forces overlay scrollers, overriding the system "Show scroll bars:
Always" preference — a common motor/vision accessibility choice.

## Current state

- HUD: `Sources/Nickel/Panel/CaptureHUD.swift:108-130` builds the panel
  (`ignoresMouseEvents = true`, nonactivating); `:155-160` the icon:

```swift
icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
```

  No `NSAccessibility.post` anywhere in the file. Find the show entry point
  (`grep -n "func show" Sources/Nickel/Panel/CaptureHUD.swift`) — it
  receives the message string.
- ⋯ menu label: `Sources/Nickel/Panel/PanelView.swift:417-419` — bare
  `Image(systemName: "ellipsis")`, no `.accessibilityLabel`/`.help`.
- Paperclip: `PanelView.swift:552-557` — bare `Image(systemName: "paperclip")`.
  (The composer row above it has `.accessibilityLabel("Add a note")` — an
  in-repo exemplar of the convention; another is
  `LogbookView.swift:129-130`'s back button with both `.accessibilityLabel`
  and `.help`.)
- Status item: `Sources/Nickel/AppDelegate.swift:18-24` — `item.button`
  gets an image/target/action, no accessibility label, no `toolTip`.
- Headers: `Sources/Nickel/Panel/SectionHeader.swift:24-30` —
  `Text(name.uppercased())`; `Sources/Nickel/Panel/LogbookView.swift:68-71`
  — `Text(Self.dayFormatter.string(from: day).uppercased())`. Neither has
  `.accessibilityAddTraits(.isHeader)` or an original-casing label.
- Scrollers: `Sources/Nickel/Panel/NoteListTable.swift:211` —
  `scrollView.scrollerStyle = .overlay` (with `autohidesScrollers = true`
  at `:210`).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | all pass |
| Probe | `NICKEL_UI_PROBE=1 .build/debug/Nickel` | all checks passed |

## Scope

**In scope**: the six files above, each at the cited sites only.

**Out of scope**:
- Overlay dim/Reduce Motion/focus rings (plan 038).
- Palette/context-menu accessibility (native NSMenu/table rows already
  carry roles).
- Any visual redesign; `.uppercased()` stays as the VISUAL treatment.

## Git workflow

- Branch: `advisor/037-a11y-essentials` from `main`
  (`git checkout -b advisor/037-a11y-essentials main`).

## Steps

### Step 1: HUD announcement

In the HUD's show path, after ordering the panel front, post:

```swift
NSAccessibility.post(
    element: NSApp.mainWindow ?? panel,
    notification: .announcementRequested,
    userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
    ]
)
```

(Verify the exact userInfo key spellings against the SDK —
`NSAccessibility.NotificationUserInfoKey.announcement` / `.priority`.)
Give the icon a real description: pass the message-appropriate
`accessibilityDescription` (e.g. nil → use the HUD message itself is
wrong for an icon; use a short noun like "Captured" / the symbol's
meaning — derive from the call sites: find what symbols are shown,
`grep -n "show(" Sources -r | grep -i hud`).

**Verify**: `swift build` → exit 0.

### Step 2: Labels and tooltips

- ⋯ menu label image: add `.accessibilityLabel("More")` and
  `.help("More options")` on the label content (place modifiers so they
  apply to the `Menu`'s label per SwiftUI semantics — on the `Menu` itself
  if attaching to the label doesn't take; verify by building).
- Paperclip: `.accessibilityLabel("Attach files")`, `.help("Attach files")`.
- Status item: `button.toolTip = "Nickel"` and
  `button.setAccessibilityLabel("Nickel")`.

**Verify**: `swift build` → exit 0.

### Step 3: Header semantics

On both header `Text`s: keep the uppercase VISUAL via `.textCase(.uppercase)`
applied to `Text(name)` (drop the manual `.uppercased()` — locale-safe),
then add `.accessibilityLabel(name)` (original casing; for day headers, the
formatted string un-uppercased) and `.accessibilityAddTraits(.isHeader)`.
Confirm rendering is pixel-identical (the tracking/font stays; only the
uppercasing mechanism changes) — the probe's header-height check must not
move.

**Verify**: `swift build`; probe → all checks passed.

### Step 4: Scroller preference

Delete `scrollView.scrollerStyle = .overlay` (`NoteListTable.swift:211`).
`NSScrollView` then follows `NSScroller.preferredScrollerStyle` (the
user's system setting) automatically, including live changes. Keep
`autohidesScrollers = true`. Check the visual consequence: with legacy
scrollers a gutter appears; the probe's width-sensitive checks (cell width
299 vs table 311 assumptions) must still pass — they read live values, so
they should. Run the probe to confirm.

**Verify**: probe → all checks passed; `swift test` → all pass.

## Test plan

No new XCTests (all sites are view attributes). Probe re-run is the
regression gate for geometry. Manual note for the human: with VoiceOver on,
(a) capture a selection → announcement heard, including the no-text
failure; (b) VO-navigate to ⋯ and paperclip → labels read; (c) rotor →
Headings lists the section names; (d) System Settings "Show scroll bars:
Always" → the list shows a persistent scroller.

## Done criteria

- [ ] `swift build` exit 0, no warnings
- [ ] `swift test` all pass; probe all pass
- [ ] `grep -n "scrollerStyle" Sources/Nickel/Panel/NoteListTable.swift` → no matches
- [ ] `grep -rn "accessibilityDescription: nil" Sources/Nickel/Panel/CaptureHUD.swift` → no matches
- [ ] `grep -n "uppercased()" Sources/Nickel/Panel/SectionHeader.swift Sources/Nickel/Panel/LogbookView.swift` → no matches
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails.
- `.textCase(.uppercase)` changes rendered metrics (probe header-height
  check fails) — fall back to keeping `.uppercased()` plus the
  accessibility modifiers, and note it.
- The announcement API requires an element the HUD architecture can't
  provide (posting from a non-key panel fails silently is NOT detectable
  headlessly — do not chase it; ship the documented-correct call and flag
  manual verification).

## Maintenance notes

- New icon-only controls must ship with `.accessibilityLabel` + `.help`;
  reviewer checklist item.
- If the HUD ever gains more message types, the announcement must carry
  them too.
