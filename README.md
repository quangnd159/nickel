# Nickel

Nickel started as a shameless copy of
[Copper by shadcn](https://shadcn.com/copper). Two reasons: I wanted to save
the $39, and I wanted to see what Claude could build. Hence the name, which
sounds like "nick all", as in "ooh, that sounds nice, I'll nick it." If you
want the original (and to support the person who designed it),
[buy Copper](https://shadcn.com/copper) instead.

From this version on, Nickel goes its own way. It no longer tracks Copper;
it grows into whatever suits my own workflow.

Copied or not, the bar hasn't moved: native AppKit/SwiftUI following macOS
platform conventions and the Human Interface Guidelines, Finder-idiom
interactions (inline rename, confirm-only-when-destructive), full keyboard
operability, defensive persistence (atomic writes, corruption recovery,
orphan cleanup), and deliberate visual design. No slop, no shortcuts that
show.

Nickel is a clipboard that remembers: double-tap the left Shift key anywhere
to capture whatever text you have selected (formatting included), or
double-tap the right Shift key to toggle a floating panel. It was built for
working with AI agents: while an agent runs, capture anything you'll want to
ask or tell it later — an error message, a snippet, a stray idea — without
switching away from what you're doing, then feed it back into Claude,
ChatGPT, or Cursor when the moment comes. Notes are checkable, so it doubles
as a to-do list; in practice it's a very versatile clipboard.
Notes are stored in a local JSON file: no accounts, no sync, no cloud.

## Features

- **Global double-Shift capture**: double-tap the left Shift key while text is
  selected in any app to snapshot it straight into Nickel with formatting
  preserved as Markdown (a ⌘C pasteboard snapshot, cross-checked against the
  Accessibility-reported selection so a wrong copy falls back to plain text), with a small "Captured" HUD
  confirming it — without stealing focus from what you were doing. If nothing's
  selected, a small HUD says so instead.
- **Global double-Shift panel toggle**: double-tap the right Shift key
  anywhere to show or hide the floating panel.
- **Floating panel**: a borderless, always-on-top scratchpad panel with search,
  a note composer, checkable notes, multi-select, inline editing, expand/
  collapse for long notes, and drag-and-drop reordering — drag within a
  section to reorder, or across sections in Show All to move. "Move to
  Section" is also available via right-click or ⌃⌘M.
- **Sections**: named groups managed straight from their header — rename,
  reorder (Move Up/Down), clear done notes in just that section, dissolve
  (ungroup, keeping the notes), or delete outright (choosing to move its
  notes to the Logbook or delete them). Cycle through Show All and each
  section with ⇧⌘] / ⇧⌘[.
- **Standard app chrome**: Nickel is a regular macOS app — Dock icon, full
  "Nickel" menu bar when active, About panel, and update checks, with full
  Edit/View/Window/Help menus. A menu bar item is also shown (left-click
  toggles the panel; right-click shows an overflow menu), with a Settings
  toggle to hide it for hotkey-first use.
- **Panel overflow menu**: section switching, Clear Done, Open Logbook, Copy
  All as List, Reveal Notes in Finder, Keyboard Shortcuts, a Keep on Top
  toggle, Close, Settings…, and Quit.
- **Customizable hotkeys**: pick a different key for capture and for the
  panel toggle in Settings — double-tap the chosen key from anywhere, same
  as the defaults.
- **Mark notes as done when copied**: an optional Settings toggle that checks
  a note off automatically the moment you copy it.
- **Frame persistence**: the panel remembers where you left it (position and
  size) across relaunches, and clamps back onscreen if a display is
  disconnected.
- **Duplicate-capture guard**: double-tapping left Shift twice on the same
  selection within 2 seconds won't create a second note.
- **Note length cap**: individual notes are capped at 20,000 characters
  (truncated with `…`) so an accidental "select all" on a huge document can't
  bloat the notes file.
- **Logbook**: Clear Done (global or per-section) archives notes instead of
  deleting them. The Logbook, opened from the overflow menu or the ⌘K
  palette, lists cleared notes grouped by day, newest first; put a note back
  (to its section, or ungrouped if the section is gone) or delete it
  permanently, with confirmation.
- **Local-only storage**: notes live in a plain JSON file on disk. No
  accounts, no telemetry, no cloud sync.

## Keyboard shortcuts

| Shortcut | Action                                                    |
| -------- | ---------------------------------------------------------- |
| **Left ⇧⇧**  | Capture the current selection                          |
| **Right ⇧⇧** | Toggle the floating panel                               |
| **⌘K**   | Commands, or switch section                                  |
| **⌃⌘M**  | Move the selected note(s) to a section                       |
| **⇧⌘]**  | Next section                                                 |
| **⇧⌘[**  | Previous section                                             |
| **⇧⌘R**  | Rename the focused section                                   |
| **⌘N**   | Focus the composer                                          |
| **⌘F**   | Focus search                                                |
| **⌘A**   | Select all notes                                            |
| **⌘C**   | Copy selected note(s) as plain text                         |
| **⇧⌘C**  | Copy selected note(s) as a numbered list                     |
| **Space**| Toggle done / not-done on the selection                     |
| **⌘E**   | Expand/collapse the selected note(s)                        |
| **Return**| Edit the selected note (single selection only)              |
| **⌘Return**| Edit the selected note in a new window                     |
| **⇧⌘M**  | Merge the selected notes into one                            |
| **⌫**    | Delete the selected note(s)                                 |
| **⌥⌫**   | Move the selected note(s) to the Logbook                     |
| **Esc**  | Clear selection, cancel an edit, or dismiss the panel        |
| **⌘W**   | Close the panel                                              |
| **⌘,**   | Open Settings                                                |
| **⌘/**   | Show this keyboard shortcuts card                            |

Arrow keys move the selection; hold ⇧ to extend a range.

## Build & install

Requires macOS 26+ and the Xcode Command Line Tools (`xcode-select --install`)
— a full Xcode.app install also works and isn't required either way.

```bash
swift build                          # compile the SwiftPM executable (debug)
bash scripts/build-app.sh            # release build, assemble build/Nickel.app, code-sign it
bash scripts/build-app.sh --install  # same, then install to /Applications/Nickel.app
```

### Accessibility permission

On first launch, Nickel prompts for **Accessibility** access (System
Settings → Privacy & Security → Accessibility). This is required so it can
detect the global double-Shift gesture and read the current text selection
from other apps. Nickel polls for the permission and starts up automatically
once it's granted — no relaunch needed.

### Signing note

`scripts/build-app.sh` signs with a self-signed "Nickel Dev Signing" identity
in the login keychain when it's present and trusted, falling back to ad-hoc
(`codesign --sign -`) otherwise. With the "Nickel Dev Signing" certificate
installed and trusted, the signature stays stable across rebuilds, so macOS
keeps recognizing the app as the same one and your Accessibility grant
survives rebuilds. Under the ad-hoc fallback there's no stable identity:
every rebuild makes macOS treat the app as "new" and re-prompt for
Accessibility access. If double-Shift stops being detected after a rebuild,
re-grant Accessibility access for Nickel in System Settings.

## License

MIT — see [LICENSE](LICENSE).
