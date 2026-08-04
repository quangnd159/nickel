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
    case editInNewWindow
    case toggleDone
    case delete
    case escape
    case copy
    case toggleExpanded
    case copyAsList
    case merge
}

/// How a command is recognized in an incoming `NSEvent`. `keyCode` entries
/// state their modifier policy explicitly: `nil` matches whatever modifiers
/// are held (the arrows need this — ⇧↑/⇧↓ extend the selection through the
/// same two commands), while an exact set matches only that set. Return uses
/// the exact form so plain ↩ (edit inline) and ⌘↩ (edit in a new window)
/// stay distinct rather than both firing. `character` entries match on
/// `charactersIgnoringModifiers` (lowercased) plus an exact modifier set.
enum PanelShortcutMatch {
    case keyCode(UInt16, modifiers: NSEvent.ModifierFlags?)
    case keyCodes([UInt16])
    case character(String, modifiers: NSEvent.ModifierFlags)

    func matches(_ event: NSEvent) -> Bool {
        switch self {
        case .keyCode(let code, let modifiers):
            guard event.keyCode == code else { return false }
            return modifiers.map { $0 == Self.exactModifiers(of: event) } ?? true
        case .keyCodes(let codes):
            return codes.contains(event.keyCode)
        case .character(let character, let modifiers):
            return Self.exactModifiers(of: event) == modifiers
                && event.charactersIgnoringModifiers?.lowercased() == character
        }
    }

    private static func exactModifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .shift, .option, .control])
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
            match: .keyCode(125, modifiers: nil),
            menuShortcut: nil,
            overlay: ("Move selection", ["↓"])
        ),
        PanelShortcut(
            command: .moveUp,
            match: .keyCode(126, modifiers: nil),
            menuShortcut: nil,
            overlay: ("Move selection", ["↑"])
        ),
        PanelShortcut(
            command: .edit,
            match: .keyCode(36, modifiers: []),
            menuShortcut: KeyboardShortcut(.return, modifiers: []),
            overlay: ("Edit note", ["↩"])
        ),
        PanelShortcut(
            command: .editInNewWindow,
            match: .keyCode(36, modifiers: [.command]),
            menuShortcut: KeyboardShortcut(.return, modifiers: .command),
            overlay: ("Edit in new window", ["⌘", "↩"])
        ),
        PanelShortcut(
            command: .toggleDone,
            match: .keyCode(49, modifiers: nil),
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
            match: .keyCode(53, modifiers: nil),
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
