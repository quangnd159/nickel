# Nickel

Nickel is a personal-use knockoff of [Copper by shadcn](https://shadcn.com/copper),
built because I wanted the workflow it describes and didn't want to wait. If
you want the real, polished thing — and to support the person who designed
it — [buy Copper](https://shadcn.com/copper) instead. This is a rough,
free stand-in for personal use, not a replacement for it.

Nickel is a macOS menu-bar scratchpad: double-tap the left Shift key anywhere
to capture whatever text you have selected, or double-tap the right Shift
key to toggle a floating panel. It's part to-do list, part clipboard, part
scratchpad for AI-chat workflows — jot down prompts or snippets, then copy
them back into Claude, ChatGPT, or Cursor, and check them off as you go.
Notes are stored in a local JSON file: no accounts, no sync, no cloud.

## Features

- **Global double-Shift capture**: double-tap the left Shift key while text is
  selected in any app to snapshot it straight into Nickel (via Accessibility,
  falling back to a ⌘C pasteboard snapshot), with a small "Captured" HUD
  confirming it — without stealing focus from what you were doing. If nothing's
  selected, a small HUD says so instead.
- **Global double-Shift panel toggle**: double-tap the right Shift key
  anywhere to show or hide the floating panel.
- **Floating panel**: a borderless, always-on-top scratchpad panel with search,
  a note composer, checkable notes, multi-select, inline editing, expand/
  collapse for long notes, and drag-free custom lists ("Move to…").
- **Menu bar item**: left-click toggles the panel; right-click shows an
  overflow menu (Toggle Panel, Quit).
- **Panel overflow menu**: Copy All as List, a Launch at Login toggle, and
  Quit.
- **Frame persistence**: the panel remembers where you left it (position and
  size) across relaunches, and clamps back onscreen if a display is
  disconnected.
- **Duplicate-capture guard**: double-tapping left Shift twice on the same
  selection within 2 seconds won't create a second note.
- **Note length cap**: individual notes are capped at 20,000 characters
  (truncated with `…`) so an accidental "select all" on a huge document can't
  bloat the notes file.
- **Local-only storage**: notes live in a plain JSON file on disk. No
  accounts, no telemetry, no cloud sync.

## Keyboard shortcuts

| Shortcut | Action                                                    |
| -------- | ---------------------------------------------------------- |
| **Left ⇧⇧**  | Capture the current selection                          |
| **Right ⇧⇧** | Toggle the floating panel                               |
| **⌘N**   | Focus the composer                                          |
| **⌘F**   | Focus search                                                |
| **⌘A**   | Select all notes                                            |
| **⌘C**   | Copy selected note(s) as plain text                         |
| **⇧⌘C**  | Copy selected note(s) as a `- ` bulleted list                |
| **Space**| Toggle done / not-done on the selection                     |
| **⌘E**   | Expand/collapse the selected note(s)                        |
| **Return**| Edit the selected note (single selection only)              |
| **⇧⌘M**  | Merge the selected notes into one                            |
| **⌫**    | Delete the selected note(s)                                 |
| **Esc**  | Clear selection, cancel an edit, or dismiss the panel        |

Arrow keys move the selection; hold ⇧ to extend a range.

## Build & install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`)
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
