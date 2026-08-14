import AppKit
import SwiftUI

/// The panel's keyboard shortcuts used to live in three places that could
/// silently drift out of sync: `FloatingPanel.handle` matched raw
/// keyCodes/characters and called `PanelActions` directly, `NoteRow`'s
/// context menu declared its own decorative `.keyboardShortcut`s (display-only
/// hints — they don't register globally on macOS, see the comment on
/// `PanelActions.toggleExpanded`), and `ShortcutsOverlay` hand-listed key
/// names for display. This file holds two tables, split by which key-event
/// path dispatches them:
///
/// - `PanelShortcuts`/`PanelCommand`: the twelve note-level commands, matched
///   in `FloatingPanel.keyDown` (via `handle(_:actions:)`) against whatever
///   currently has focus — they don't fire while a text field is editing.
/// - `WindowShortcuts`/`WindowCommand`: the ten window/navigation commands
///   (⌘K, ⌃⌘M, ⌘/, ⌘F, ⌘N, ⌘W, ⌘,, ⇧⌘], ⇧⌘[, ⇧⌘R), matched in
///   `FloatingPanel.performKeyEquivalent`, which runs ahead of any focused
///   field so these always fire regardless of what has focus.
///
/// Each table is read by the same three consumers: the matching itself, the
/// menu (`AppDelegate`'s View/File/Edit items or `NoteContextMenu`'s
/// `NSMenuItem`s), and `ShortcutsOverlay`'s display card.
enum PanelCommand: CaseIterable {
    case moveDown
    case moveUp
    case edit
    case editInNewWindow
    case toggleDone
    case delete
    case moveToLogbook
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
    case keyCodes([UInt16], modifiers: NSEvent.ModifierFlags?)
    case character(String, modifiers: NSEvent.ModifierFlags)

    func matches(_ event: NSEvent) -> Bool {
        switch self {
        case .keyCode(let code, let modifiers):
            guard event.keyCode == code else { return false }
            return modifiers.map { $0 == Self.exactModifiers(of: event) } ?? true
        case .keyCodes(let codes, let modifiers):
            guard codes.contains(event.keyCode) else { return false }
            return modifiers.map { $0 == Self.exactModifiers(of: event) } ?? true
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
    /// The same hint as `menuShortcut`, spelled for `NSMenuItem`: the note
    /// row's contextual menu is an `NSMenu` now (see `NoteContextMenu`), and
    /// SwiftUI's `KeyboardShortcut` can't be read back out for it. Present
    /// exactly when `menuShortcut` is — asserted by `PanelShortcutsTests`.
    let menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)?
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
            menuKeyEquivalent: nil,
            overlay: ("Move selection", ["↓"])
        ),
        PanelShortcut(
            command: .moveUp,
            match: .keyCode(126, modifiers: nil),
            menuShortcut: nil,
            menuKeyEquivalent: nil,
            overlay: ("Move selection", ["↑"])
        ),
        PanelShortcut(
            command: .edit,
            match: .keyCode(36, modifiers: []),
            menuShortcut: KeyboardShortcut(.return, modifiers: []),
            menuKeyEquivalent: ("\r", []),
            overlay: ("Edit note", ["↩"])
        ),
        PanelShortcut(
            command: .editInNewWindow,
            match: .keyCode(36, modifiers: [.command]),
            menuShortcut: KeyboardShortcut(.return, modifiers: .command),
            menuKeyEquivalent: ("\r", .command),
            overlay: ("Edit in new window", ["⌘", "↩"])
        ),
        PanelShortcut(
            command: .toggleDone,
            match: .keyCode(49, modifiers: nil),
            menuShortcut: KeyboardShortcut(" ", modifiers: []),
            menuKeyEquivalent: (" ", []),
            overlay: ("Toggle done", ["Space"])
        ),
        PanelShortcut(
            command: .delete,
            match: .keyCodes([51, 117], modifiers: []),
            menuShortcut: KeyboardShortcut(.delete, modifiers: []),
            menuKeyEquivalent: ("\u{8}", []),
            overlay: ("Delete", ["⌫"])
        ),
        PanelShortcut(
            command: .moveToLogbook,
            match: .keyCodes([51, 117], modifiers: [.option]),
            menuShortcut: KeyboardShortcut(.delete, modifiers: .option),
            menuKeyEquivalent: ("\u{8}", .option),
            overlay: ("Move to Logbook", ["⌥", "⌫"])
        ),
        PanelShortcut(
            command: .escape,
            match: .keyCode(53, modifiers: nil),
            menuShortcut: nil,
            menuKeyEquivalent: nil,
            overlay: nil
        ),
        PanelShortcut(
            command: .copy,
            match: .character("c", modifiers: [.command]),
            menuShortcut: KeyboardShortcut("c", modifiers: .command),
            menuKeyEquivalent: ("c", .command),
            overlay: ("Copy", ["⌘", "C"])
        ),
        PanelShortcut(
            command: .toggleExpanded,
            match: .character("e", modifiers: [.command]),
            menuShortcut: KeyboardShortcut("e", modifiers: .command),
            menuKeyEquivalent: ("e", .command),
            overlay: ("Expand/collapse", ["⌘", "E"])
        ),
        PanelShortcut(
            command: .copyAsList,
            match: .character("c", modifiers: [.command, .shift]),
            menuShortcut: KeyboardShortcut("c", modifiers: [.command, .shift]),
            menuKeyEquivalent: ("c", [.command, .shift]),
            overlay: ("Copy as list", ["⇧", "⌘", "C"])
        ),
        PanelShortcut(
            command: .merge,
            match: .character("m", modifiers: [.command, .shift]),
            menuShortcut: KeyboardShortcut("m", modifiers: [.command, .shift]),
            menuKeyEquivalent: ("m", [.command, .shift]),
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

// MARK: - Window/navigation shortcuts

/// The ten window-level shortcuts: opening the section switcher/move
/// palette or the shortcuts card, focusing search/composer, closing the
/// panel, opening Settings, cycling sections, and renaming the active
/// section. See the file-top doc comment for how this differs from
/// `PanelCommand`.
enum WindowCommand: CaseIterable {
    case sectionSwitcher
    case moveToSection
    case shortcutsCard
    case findFocus
    case newNote
    case closePanel
    case settings
    case nextSection
    case previousSection
    case renameSection
}

/// How a `WindowCommand` is recognized in an incoming `NSEvent`. Separate
/// from `PanelShortcutMatch` because the bracket pair (⇧⌘]/⇧⌘[) needs to
/// accept more than one `charactersIgnoringModifiers` value plus a keyCode
/// fallback — see the case's own doc comment.
enum WindowShortcutMatch {
    case character(String, modifiers: NSEvent.ModifierFlags)
    /// Matches if `charactersIgnoringModifiers` (lowercased) is any of
    /// `characters`, or `event.keyCode == keyCodeFallback`. Needed for ⇧⌘]/
    /// ⇧⌘[: with Shift held, `charactersIgnoringModifiers` can deliver either
    /// the bracket itself or its shifted form ("}"/"{") depending on keyboard
    /// layout, so the keyCode (30 = ']', 33 = '[' on ANSI) is checked as a
    /// robust fallback alongside the characters.
    case characters([String], modifiers: NSEvent.ModifierFlags, keyCodeFallback: UInt16)

    func matches(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch self {
        case .character(let character, let requiredModifiers):
            return modifiers == requiredModifiers
                && event.charactersIgnoringModifiers?.lowercased() == character
        case .characters(let characters, let requiredModifiers, let keyCodeFallback):
            guard modifiers == requiredModifiers else { return false }
            if let current = event.charactersIgnoringModifiers?.lowercased(), characters.contains(current) {
                return true
            }
            return event.keyCode == keyCodeFallback
        }
    }
}

/// Which group a `WindowShortcut` renders under on the ⌘/ card
/// (`ShortcutsOverlay`'s "Navigate" and "Window" sections).
enum WindowShortcutGroup {
    case navigate
    case window
}

struct WindowShortcut {
    let command: WindowCommand
    let match: WindowShortcutMatch
    /// Title for the menu item that triggers this command (View, File, or
    /// Edit — see `AppDelegate.setupMainMenu`). Ends in "…" exactly when the
    /// command opens further UI (a palette, Settings, or the rename field) —
    /// asserted by `PanelShortcutsTests`.
    let menuTitle: String
    let menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)
    let overlayGroup: WindowShortcutGroup
    let overlay: (label: String, keys: [String])
}

enum WindowShortcuts {
    static let all: [WindowShortcut] = [
        WindowShortcut(
            command: .sectionSwitcher,
            match: .character("k", modifiers: [.command]),
            menuTitle: "Switch Section…",
            menuKeyEquivalent: ("k", [.command]),
            overlayGroup: .navigate,
            overlay: ("Commands, or switch section", ["⌘", "K"])
        ),
        WindowShortcut(
            command: .moveToSection,
            match: .character("m", modifiers: [.command, .control]),
            menuTitle: "Move to Section…",
            menuKeyEquivalent: ("m", [.command, .control]),
            overlayGroup: .navigate,
            overlay: ("Move to Section", ["⌃", "⌘", "M"])
        ),
        WindowShortcut(
            command: .nextSection,
            match: .characters(["]", "}"], modifiers: [.command, .shift], keyCodeFallback: 30),
            menuTitle: "Next Section",
            menuKeyEquivalent: ("]", [.command, .shift]),
            overlayGroup: .navigate,
            overlay: ("Next section", ["⇧", "⌘", "]"])
        ),
        WindowShortcut(
            command: .previousSection,
            match: .characters(["[", "{"], modifiers: [.command, .shift], keyCodeFallback: 33),
            menuTitle: "Previous Section",
            menuKeyEquivalent: ("[", [.command, .shift]),
            overlayGroup: .navigate,
            overlay: ("Previous section", ["⇧", "⌘", "["])
        ),
        WindowShortcut(
            command: .renameSection,
            match: .character("r", modifiers: [.command, .shift]),
            menuTitle: "Rename Section…",
            menuKeyEquivalent: ("r", [.command, .shift]),
            overlayGroup: .navigate,
            overlay: ("Rename section", ["⇧", "⌘", "R"])
        ),
        WindowShortcut(
            command: .findFocus,
            match: .character("f", modifiers: [.command]),
            menuTitle: "Find",
            menuKeyEquivalent: ("f", [.command]),
            overlayGroup: .navigate,
            overlay: ("Search", ["⌘", "F"])
        ),
        WindowShortcut(
            command: .newNote,
            match: .character("n", modifiers: [.command]),
            menuTitle: "New Note",
            menuKeyEquivalent: ("n", [.command]),
            overlayGroup: .navigate,
            overlay: ("New note", ["⌘", "N"])
        ),
        WindowShortcut(
            command: .shortcutsCard,
            match: .character("/", modifiers: [.command]),
            menuTitle: "Keyboard Shortcuts",
            menuKeyEquivalent: ("/", [.command]),
            overlayGroup: .navigate,
            overlay: ("Keyboard shortcuts", ["⌘", "/"])
        ),
        WindowShortcut(
            command: .closePanel,
            match: .character("w", modifiers: [.command]),
            menuTitle: "Close",
            menuKeyEquivalent: ("w", [.command]),
            overlayGroup: .window,
            overlay: ("Close panel", ["⌘", "W"])
        ),
        WindowShortcut(
            command: .settings,
            match: .character(",", modifiers: [.command]),
            menuTitle: "Settings…",
            menuKeyEquivalent: (",", [.command]),
            overlayGroup: .window,
            overlay: ("Settings", ["⌘", ","])
        )
    ]

    /// The command matching `event`, if any. Mirrors `PanelShortcuts.command(for:)`.
    static func command(for event: NSEvent) -> WindowCommand? {
        all.first { $0.match.matches(event) }?.command
    }

    /// Every command appears exactly once in `all`, so this is total.
    static func shortcut(for command: WindowCommand) -> WindowShortcut {
        guard let shortcut = all.first(where: { $0.command == command }) else {
            preconditionFailure("WindowShortcuts.all is missing an entry for \(command)")
        }
        return shortcut
    }
}
