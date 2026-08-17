import AppKit

/// The note row's contextual menu, built as an `NSMenu` so the table keeps its
/// native right-click behavior (the clicked row picked from the event, and a
/// selection that's adjusted before the menu opens).
///
/// A SwiftUI `.contextMenu` on the row's content isn't an option any more: the
/// row's hosting view has to stay invisible to the mouse for the table's own
/// click handling to work at all. Titles, order, separators, shortcut hints
/// and enable/disable rules mirror the old SwiftUI menu exactly.
enum NoteContextMenu {
    static func menu(
        mode: NoteListMode,
        store: NoteStore,
        selection: SelectionModel,
        actions: PanelActions
    ) -> NSMenu {
        switch mode {
        case .notes: return notesMenu(store: store, selection: selection, actions: actions)
        case .logbook: return logbookMenu(selection: selection, actions: actions)
        }
    }

    private static func notesMenu(store: NoteStore, selection: SelectionModel, actions: PanelActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(item("Copy", .copy) { actions.copy() })
        menu.addItem(item("Copy as List", .copyAsList) { actions.copyAsList() })
        menu.addItem(.separator())

        menu.addItem(item(
            actions.allSelectedAreDone ? "Mark as Not Done" : "Mark as Done",
            .toggleDone
        ) { actions.toggleDone() })

        menu.addItem(item(
            actions.allSelectedAreExpanded ? "Collapse" : "Expand",
            .toggleExpanded,
            enabled: !selection.selectedIDs.isEmpty
        ) { actions.toggleExpanded() })

        menu.addItem(item("Edit", .edit, enabled: selection.selectedIDs.count == 1) {
            actions.startEditingIfSingleSelected()
        })
        menu.addItem(item("Edit in New Window", .editInNewWindow, enabled: selection.selectedIDs.count == 1) {
            actions.editInNewWindow()
        })
        menu.addItem(item("Merge Notes", .merge, enabled: selection.selectedIDs.count >= 2) {
            actions.merge()
        })

        let moveItem = NSMenuItem(title: "Move to Section", action: nil, keyEquivalent: "")
        let moveMenu = NSMenu()
        moveMenu.autoenablesItems = false
        for sectionName in store.sections {
            moveMenu.addItem(item(sectionName, nil) { actions.move(toSection: sectionName) })
        }
        moveMenu.addItem(item("No Section", nil) { actions.move(toSection: nil) })
        moveMenu.addItem(.separator())
        moveMenu.addItem(item("New Section with Selection", nil) { actions.createSectionWithSelection() })
        moveItem.submenu = moveMenu
        menu.addItem(moveItem)

        menu.addItem(.separator())
        menu.addItem(item("Move to Logbook", .moveToLogbook) { actions.moveToLogbook() })
        menu.addItem(item("Delete", .delete) { actions.delete() })
        return menu
    }

    private static func logbookMenu(selection: SelectionModel, actions: PanelActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let ids = selection.selectedIDs
        menu.addItem(item("Put Back", nil) { actions.restore(ids: ids) })
        menu.addItem(.separator())
        menu.addItem(item("Delete Permanently", nil) { actions.requestPermanentDelete(ids: ids) })
        return menu
    }

    private static func item(
        _ title: String,
        _ command: PanelCommand?,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: #selector(MenuActionTarget.fire), keyEquivalent: "")
        let target = MenuActionTarget(action: action)
        menuItem.target = target
        // `NSMenuItem` doesn't retain its target, and nothing else here owns
        // the closure box, so the item holds it as its represented object.
        menuItem.representedObject = target
        menuItem.isEnabled = enabled
        if let command, let key = PanelShortcuts.shortcut(for: command).menuKeyEquivalent {
            menuItem.keyEquivalent = key.key
            menuItem.keyEquivalentModifierMask = key.modifiers
        }
        return menuItem
    }
}

/// Boxes a closure as a menu item's target/action pair.
private final class MenuActionTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire() { action() }
}
