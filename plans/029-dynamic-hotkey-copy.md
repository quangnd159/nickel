# Plan 029: Make the empty state and ⌘/ card reflect the configured hotkeys

> **Executor instructions**: Follow this plan step by step, verifying each
> step. On any STOP condition, stop and report. Update this plan's row in
> `plans/README.md` when done — unless a reviewer told you they maintain the
> index.
>
> **Drift check (run first)**: `git diff --stat 62bbcb6..HEAD -- Sources/Nickel/Panel/ShortcutsOverlay.swift Sources/Nickel/Panel/PanelView.swift Sources/Nickel/HotkeyMonitor.swift`
> On change, compare excerpts; mismatch = STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `62bbcb6`, 2026-08-14

## Why this matters

The capture and panel-toggle hotkeys are user-configurable across 8 modifier
keys (Settings pickers), but the app's two self-descriptions hardcode Shift:
the first-run empty state says "Double-tap left Shift anywhere to capture"
and the ⌘/ shortcuts card shows literal `⇧⇧ left` / `⇧⇧ right` rows. A user
who changes either picker is then instructed, by the app itself, to perform
a gesture that does nothing. After this plan both surfaces derive their copy
from the live settings and update when they change.

## Current state

- `Sources/Nickel/Panel/ShortcutsOverlay.swift:37-40`:

```swift
group("Capture", [
    ShortcutRow("Capture selection", ["⇧⇧", "left"]),
    ShortcutRow("Show/hide panel", ["⇧⇧", "right"])
])
```

  `ShortcutRow` takes a title and an array of key-cap strings.
- `Sources/Nickel/Panel/PanelView.swift:516` (inside `emptyState`):

```swift
Text("Double-tap left Shift anywhere to capture")
```

- The source of truth: `PanelSettings.captureKey` / `PanelSettings.panelToggleKey`
  (`Sources/Nickel/Support/PanelSettings.swift:75+`), of type `ModifierKey`
  (`Sources/Nickel/HotkeyMonitor.swift:6-40`). Change notifications exist:
  `PanelSettings.captureKeyDidChange` / `.panelToggleKeyDidChange`
  (`PanelSettings.swift:64-70`); `SettingsView.swift:98-103` shows the
  `.onReceive` observation pattern to copy.
- Display helper today: `ModifierKey.displayName` (`HotkeyMonitor.swift:56-67`)
  returns e.g. `"⇧ Left Shift"` — glyph + side + name in one string. The two
  UI surfaces need the parts separately (glyph doubled for the key-caps, and
  a lowercase phrase for the sentence), so add small accessors rather than
  parsing `displayName`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Tests | `swift test` | 377 + new pass |

## Scope

**In scope**:
- `Sources/Nickel/HotkeyMonitor.swift` (add display accessors on `ModifierKey`)
- `Sources/Nickel/Panel/ShortcutsOverlay.swift`
- `Sources/Nickel/Panel/PanelView.swift` (emptyState only)
- `Tests/NickelTests/` (new small test file for the accessors)

**Out of scope**:
- SettingsView (already live-updates), HotkeyMonitor's event logic,
  README (plan 041 covers docs).

## Git workflow

- Branch: `advisor/029-dynamic-hotkey-copy` from `main`
  (`git checkout -b advisor/029-dynamic-hotkey-copy main`).

## Steps

### Step 1: Display accessors

On `ModifierKey`, add:

```swift
/// "⇧" — the bare modifier glyph.
var glyph: String
/// "left" / "right" — lowercase side word.
var sideWord: String
/// "left Shift" — for mid-sentence use ("Double-tap left Shift …").
var sentencePhrase: String
```

Derive per-case (switch), consistent with `displayName`'s spellings. UI copy
rule (repo convention): sentence phrases are for end users; no jargon.

**Verify**: `swift build` → exit 0.

### Step 2: Wire the two surfaces

- `ShortcutsOverlay`: replace the two literal rows with rows built from
  `PanelSettings.captureKey` / `.panelToggleKey`:
  `ShortcutRow("Capture selection", [key.glyph + key.glyph, key.sideWord])`.
  The overlay is recreated on each presentation (mounted when
  `presentedOverlay == .shortcuts`), so live re-render mid-presentation is
  not required — but add the two `.onReceive` observers (pattern at
  `SettingsView.swift:98-103`) updating `@State` copies if the view already
  holds state; otherwise reading the settings directly in `body` is enough.
  Choose the simpler of the two that keeps the card correct when Settings
  changes while the card is open; state your choice in the report.
- `PanelView.emptyState`: replace the literal with
  `"Double-tap \(PanelSettings.captureKey.sentencePhrase) anywhere to capture"`.
  The empty state is long-lived, so it MUST observe
  `PanelSettings.captureKeyDidChange` (`.onReceive` on the view, updating an
  `@State var captureKey`), or the copy goes stale after a Settings change.

**Verify**: `swift build` → exit 0.

### Step 3: Tests

New `ModifierKeyDisplayTests.swift`: for all 8 cases assert `glyph`,
`sideWord`, `sentencePhrase` are non-empty, glyph matches the leading glyph
of `displayName`, and `sentencePhrase` contains the side word. Keep it a
table-driven loop, not 24 asserts.

**Verify**: `swift test` → 377 + new, 0 failures.

## Test plan

As Step 3; UI wiring is compile-time + a manual glance (report it for the
human: change the capture key in Settings, reopen the panel with an empty
store scope, confirm the sentence follows; open ⌘/ and confirm the rows).

## Done criteria

- [ ] `swift build` exit 0, no warnings
- [ ] `swift test` all pass, new tests included
- [ ] `grep -rn '"⇧⇧"' Sources/` → no matches
- [ ] `grep -rn "Double-tap left Shift" Sources/` → no matches
- [ ] `plans/README.md` updated

## STOP conditions

- Drift check fails.
- `ShortcutRow`'s API can't render a two-glyph cap (e.g. fixed-width caps
  clip "⇧⇧") — report with a screenshot-free description; don't redesign the
  row component.

## Maintenance notes

- Plan 041 updates the README's hotkey wording; keep phrasing consistent
  ("double-tap <key>").
- If more surfaces ever mention the hotkeys, they must read these accessors.
