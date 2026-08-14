import AppKit
import XCTest
@testable import Nickel

final class PanelShortcutsTests: XCTestCase {
    private func keyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], characters: String = "") -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private static let returnKeyCode: UInt16 = 36
    private static let downArrowKeyCode: UInt16 = 125

    func testPlainReturnEditsInline() {
        XCTAssertEqual(PanelShortcuts.command(for: keyEvent(keyCode: Self.returnKeyCode)), .edit)
    }

    func testCommandReturnEditsInNewWindow() {
        let event = keyEvent(keyCode: Self.returnKeyCode, modifiers: .command)
        XCTAssertEqual(PanelShortcuts.command(for: event), .editInNewWindow)
    }

    /// Neither Return command fires with a modifier set that matches neither
    /// exactly — the two must not overlap in either direction.
    func testShiftReturnMatchesNoCommand() {
        let event = keyEvent(keyCode: Self.returnKeyCode, modifiers: .shift)
        XCTAssertNil(PanelShortcuts.command(for: event))
    }

    /// The arrows stay modifier-agnostic, so `NoteListTableView.keyDown` can
    /// recognize ⇧↓ as the table's own extend-selection navigation and let it
    /// through rather than passing it to the panel's shortcut layer.
    func testShiftArrowStillMovesSelection() {
        let event = keyEvent(keyCode: Self.downArrowKeyCode, modifiers: .shift)
        XCTAssertEqual(PanelShortcuts.command(for: event), .moveDown)
    }

    private static let deleteKeyCode: UInt16 = 51

    func testPlainDeleteKeyDeletes() {
        let event = keyEvent(keyCode: Self.deleteKeyCode)
        XCTAssertEqual(PanelShortcuts.command(for: event), .delete)
    }

    func testOptionDeleteKeyMovesToLogbook() {
        let event = keyEvent(keyCode: Self.deleteKeyCode, modifiers: .option)
        XCTAssertEqual(PanelShortcuts.command(for: event), .moveToLogbook)
    }

    func testEveryCommandHasExactlyOneTableEntry() {
        for command in PanelCommand.allCases {
            XCTAssertEqual(PanelShortcuts.all.filter { $0.command == command }.count, 1, "\(command)")
        }
    }

    /// The row's contextual menu is an `NSMenu` (see `NoteContextMenu`) and
    /// the shortcuts card reads the SwiftUI form, so a command that shows a
    /// hint in one place must show one in the other.
    func testMenuShortcutAndItsAppKitSpellingAgreeOnWhichCommandsHaveOne() {
        for shortcut in PanelShortcuts.all {
            XCTAssertEqual(
                shortcut.menuShortcut != nil,
                shortcut.menuKeyEquivalent != nil,
                "\(shortcut.command)"
            )
        }
    }

    func testArrowsAndEscapeCarryNoMenuHint() {
        for command in [PanelCommand.moveDown, .moveUp, .escape] {
            XCTAssertNil(PanelShortcuts.shortcut(for: command).menuKeyEquivalent, "\(command)")
        }
    }

    // MARK: - WindowShortcuts

    func testEveryWindowCommandHasExactlyOneTableEntry() {
        for command in WindowCommand.allCases {
            XCTAssertEqual(WindowShortcuts.all.filter { $0.command == command }.count, 1, "\(command)")
        }
    }

    func testEveryWindowShortcutHasNonEmptyTitleAndOverlayStrings() {
        for shortcut in WindowShortcuts.all {
            XCTAssertFalse(shortcut.menuTitle.isEmpty, "\(shortcut.command)")
            XCTAssertFalse(shortcut.overlay.label.isEmpty, "\(shortcut.command)")
            XCTAssertFalse(shortcut.overlay.keys.isEmpty, "\(shortcut.command)")
        }
    }

    /// The menu equivalent and the match rule must agree on which key/
    /// modifiers fire the command — otherwise the menu item and the window's
    /// `performKeyEquivalent` interception would drift, like the bug this
    /// table exists to prevent (see `PanelShortcutsTests`' file-top note on
    /// `PanelShortcuts`).
    func testWindowMenuEquivalentAndMatchRuleAgreeOnKeyAndModifiers() {
        for shortcut in WindowShortcuts.all {
            let (key, modifiers) = shortcut.menuKeyEquivalent
            let event = keyEvent(keyCode: 0, modifiers: modifiers, characters: key)
            XCTAssertEqual(WindowShortcuts.command(for: event), shortcut.command, "\(shortcut.command)")
        }
    }

    /// HIG: a menu title ends in "…" exactly when the command opens further
    /// UI — a palette (switch/move/rename) or the Settings window.
    func testWindowTitlesEndInEllipsisExactlyWhenTheyOpenFurtherUI() {
        let opensFurtherUI: Set<WindowCommand> = [.sectionSwitcher, .moveToSection, .renameSection, .settings]
        for shortcut in WindowShortcuts.all {
            XCTAssertEqual(
                shortcut.menuTitle.hasSuffix("…"),
                opensFurtherUI.contains(shortcut.command),
                "\(shortcut.command)"
            )
        }
    }
}
