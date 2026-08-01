import AppKit
import SwiftUI

/// The panel's keyboard shortcuts used to live in three places that could
/// silently drift out of sync: `FloatingPanel.handle` matched raw
/// keyCodes/characters and called `PanelActions` directly, `NoteRow`'s
/// context menu declared its own decorative `.keyboardShortcut`s (display-only
/// hints — they don't register globally on macOS, see the comment on
/// `PanelActions.toggleExpanded`), and `ShortcutsOverlay` hand-listed key
/// names for display. This file is the one table all three read from: each
/// `PanelShortcut` owns the rule that matches it against an `NSEvent`, the
/// `KeyboardShortcut` shown on its context-menu item (where one exists), and
/// the strings the shortcuts card renders.
enum PanelCommand: CaseIterable {
    case moveDown
    case moveUp
    case edit
    case toggleDone
    case delete
    case escape
    case copy
    case toggleExpanded
    case copyAsList
    case merge
}

/// How a command is recognized in an incoming `NSEvent`. The arrows, Return,
/// Space, Delete/Forward-Delete and Escape match on `keyCode` alone,
/// regardless of modifiers; the rest match on `charactersIgnoringModifiers`
/// (lowercased) plus an exact modifier-flag set.
enum PanelShortcutMatch {
    case keyCode(UInt16)
    case keyCodes([UInt16])
    case character(String, modifiers: NSEvent.ModifierFlags)

    func matches(_ event: NSEvent) -> Bool {
        switch self {
        case .keyCode(let code):
            return event.keyCode == code
        case .keyCodes(let codes):
            return codes.contains(event.keyCode)
        case .character(let character, let modifiers):
            let eventModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            return eventModifiers == modifiers && event.charactersIgnoringModifiers?.lowercased() == character
        }
    }
}

struct PanelShortcut {
    let command: PanelCommand
    let match: PanelShortcutMatch
    /// `nil` for commands with no context-menu item: the arrows (there's no
    /// "move selection" menu item) and Escape (its behavior is
    /// context-dependent — see `FloatingPanel.handle` — so it's panel logic
    /// only, never surfaced as a menu shortcut).
    let menuShortcut: KeyboardShortcut?
    /// `nil` for commands the shortcuts card doesn't list on their own.
    /// Escape isn't shown in the card at all; the arrows are shown as one
    /// combined "Move selection" row, assembled by `ShortcutsOverlay` from
    /// both entries rather than duplicated here.
    let overlay: (label: String, keys: [String])?
}

enum PanelShortcuts {
    static let all: [PanelShortcut] = [
        PanelShortcut(
            command: .moveDown,
            match: .keyCode(125),
            menuShortcut: nil,
            overlay: ("Move selection", ["↓"])
        ),
        PanelShortcut(
            command: .moveUp,
            match: .keyCode(126),
            menuShortcut: nil,
            overlay: ("Move selection", ["↑"])
        ),
        PanelShortcut(
            command: .edit,
            match: .keyCode(36),
            menuShortcut: KeyboardShortcut(.return, modifiers: []),
            overlay: ("Edit note", ["↩"])
        ),
        PanelShortcut(
            command: .toggleDone,
            match: .keyCode(49),
            menuShortcut: KeyboardShortcut(" ", modifiers: []),
            overlay: ("Toggle done", ["Space"])
        ),
        PanelShortcut(
            command: .delete,
            match: .keyCodes([51, 117]),
            menuShortcut: KeyboardShortcut(.delete, modifiers: []),
            overlay: ("Delete", ["⌫"])
        ),
        PanelShortcut(
            command: .escape,
            match: .keyCode(53),
            menuShortcut: nil,
            overlay: nil
        ),
        PanelShortcut(
            command: .copy,
            match: .character("c", modifiers: [.command]),
            menuShortcut: KeyboardShortcut("c", modifiers: .command),
            overlay: ("Copy", ["⌘", "C"])
        ),
        PanelShortcut(
            command: .toggleExpanded,
            match: .character("e", modifiers: [.command]),
            menuShortcut: KeyboardShortcut("e", modifiers: .command),
            overlay: ("Expand/collapse", ["⌘", "E"])
        ),
        PanelShortcut(
            command: .copyAsList,
            match: .character("c", modifiers: [.command, .shift]),
            menuShortcut: KeyboardShortcut("c", modifiers: [.command, .shift]),
            overlay: ("Copy as list", ["⇧", "⌘", "C"])
        ),
        PanelShortcut(
            command: .merge,
            match: .character("m", modifiers: [.command, .shift]),
            menuShortcut: KeyboardShortcut("m", modifiers: [.command, .shift]),
            overlay: ("Merge notes", ["⇧", "⌘", "M"])
        )
    ]

    /// The command matching `event`, if any. `FloatingPanel.handle` switches
    /// on the result to dispatch — the table only maps event → command, the
    /// panel still decides what each command does with the event's context
    /// (shift-extend on the arrows, the clear-selection-else-toggle branch on
    /// Escape).
    static func command(for event: NSEvent) -> PanelCommand? {
        all.first { $0.match.matches(event) }?.command
    }

    /// Every command appears exactly once in `all`, so this is total.
    static func shortcut(for command: PanelCommand) -> PanelShortcut {
        guard let shortcut = all.first(where: { $0.command == command }) else {
            preconditionFailure("PanelShortcuts.all is missing an entry for \(command)")
        }
        return shortcut
    }
}

extension View {
    /// Applies `command`'s menu-display `KeyboardShortcut`, if it has one
    /// (see `PanelShortcut.menuShortcut`'s doc comment for which commands
    /// don't).
    @ViewBuilder
    func panelKeyboardShortcut(_ command: PanelCommand) -> some View {
        if let shortcut = PanelShortcuts.shortcut(for: command).menuShortcut {
            self.keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}
