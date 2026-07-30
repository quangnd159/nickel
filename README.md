# Nickel

Nickel is a native macOS menu-bar scratchpad app: a lightweight, always-available
floating panel for quick notes, built with AppKit and SwiftUI on top of SwiftPM
(no Xcode project required). Double-tap Shift anywhere on the system to grab
whatever's selected, or bring up the panel and jot something down directly.

## Features

- **Global double-Shift capture**: double-tap Shift while text is selected in
  any app to snapshot it straight into Nickel (via Accessibility, falling back
  to a ⌘C pasteboard snapshot), with a small "Captured" HUD confirming it —
  without stealing focus from what you were doing. Double-tapping Shift with
  nothing selected instead toggles the panel.
- **Floating panel**: a borderless, always-on-top scratchpad panel with search,
  a note composer, checkable notes, multi-select, inline editing, and
  drag-free custom lists ("Move to…").
- **Menu bar item**: left-click toggles the panel; right-click shows an
  overflow menu (Toggle Panel, Quit).
- **Panel overflow menu**: Copy All as List, a Launch at Login toggle, and
  Quit.
- **Frame persistence**: the panel remembers where you left it (position and
  size) across relaunches, and clamps back onscreen if a display is
  disconnected.
- **Duplicate-capture guard**: double-shifting twice on the same selection
  within 2 seconds won't create a second note.
- **Note length cap**: individual notes are capped at 20,000 characters
  (truncated with `…`) so an accidental "select all" on a huge document can't
  bloat the notes file.

## Keyboard shortcuts

All shortcuts below apply while the panel is focused, over the current
selection (unless noted otherwise).

| Shortcut                            | Action                                                            |
| ------------------------------------ | ------------------------------------------------------------------ |
| Double-tap **Shift**                 | Capture the current selection (anywhere), or toggle the panel if nothing's selected |
| **⌘C**                               | Copy selected note(s) as plain text                                |
| **⇧⌘C**                              | Copy selected note(s) as a `- ` bulleted list                      |
| **Space**                            | Toggle done / not-done on the selection                            |
| **Return**                           | Edit the selected note (single selection only)                     |
| **⇧⌘M**                              | Merge the selected notes into one                                  |
| **⌫ / Forward Delete**               | Delete the selected note(s)                                        |
| **↑ / ↓**                            | Move the selection; hold ⇧ to extend a range                       |
| **Esc**                              | Clear selection, or hide the panel if nothing's selected            |
| **Esc** (search focused, has text)   | Clear the search, keep focus in the search field                   |
| **Esc** (search focused, empty)      | Leave the search field                                              |
| **Esc** (editing a note)             | Cancel the edit, discarding changes                                 |
| **Return** (editing a note)          | Commit the edit                                                     |

## Install & build

Requires the Xcode Command Line Tools (`xcode-select --install`) — no full
Xcode installation is needed or used.

```bash
swift build                 # compile the SwiftPM executable (debug)
bash scripts/build-app.sh   # release-build, assemble build/Nickel.app, ad-hoc code-sign it
open build/Nickel.app       # launch
```

On first launch, Nickel will prompt for **Accessibility** access (System
Settings → Privacy & Security → Accessibility). This is required so it can
detect the global double-Shift gesture and read the current text selection
from other apps. Nickel polls for the permission and starts up automatically
once it's granted — no relaunch needed.

### Ad-hoc signing caveat

`scripts/build-app.sh` code-signs the app ad-hoc (`codesign --sign -`), which
is enough to run locally but is **not a stable identity**: every time you
rebuild, macOS treats the app as "new" and will re-prompt for Accessibility
access (and may show it as already "granted" for a stale entry that no longer
matches). If double-Shift stops being detected after a rebuild, re-grant
Accessibility access for Nickel in System Settings. A real Developer ID
signature would avoid this churn for distributed builds.

## Architecture notes

- Built entirely with SwiftPM (`swift build`); there is no `.xcodeproj`.
- SwiftUI's `@State` and `@FocusState` property-wrapper macros require the
  `SwiftUIMacros` compiler plugin, which ships only with Xcode.app and isn't
  available under a CLI-tools-only `swift build`. Wherever the original
  Copper-style UI would reach for `@State`, this codebase instead uses a
  plain `ObservableObject` + `@StateObject` (e.g. `PanelUIState`,
  `SelectionModel`), or a small `NSViewRepresentable` with its own
  `Coordinator` when precise AppKit control is needed (e.g. `SearchField`,
  `InlineTextEditor`).
