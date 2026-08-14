import AppKit
import XCTest
@testable import Nickel

/// Edit ▸ Copy and Edit ▸ Delete, routed to the note list via
/// `NoteListTableView`'s responder-chain overrides (plan 027) so a
/// menu-driven or VoiceOver user can act on the note selection, not just a
/// focused field editor.
final class NoteListMenuActionsTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: NoteStore!
    private var selection: SelectionModel!
    private var actions: PanelActions!
    private var coordinator: NoteListCoordinator!
    private var tableView: NoteListTableView!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = NoteStore(fileURL: tempDirectory.appendingPathComponent("notes.json"))
        selection = SelectionModel(store: store)
        actions = PanelActions(store: store, selection: selection)

        coordinator = NoteListCoordinator(mode: .notes)
        _ = coordinator.makeScrollView()
        coordinator.update(store: store, selection: selection, actions: actions)
        tableView = coordinator.tableViewForTesting
    }

    override func tearDown() {
        tableView = nil
        coordinator = nil
        actions = nil
        selection = nil
        store = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    private func item(for selector: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: selector, keyEquivalent: "")
    }

    // MARK: - validateUserInterfaceItem

    func testCopyAndDeleteAreDisabledWithNoSelection() {
        store.add(text: "a", sourceApp: nil)

        XCTAssertFalse(tableView.validateUserInterfaceItem(item(for: #selector(NoteListTableView.copy(_:)))))
        XCTAssertFalse(tableView.validateUserInterfaceItem(item(for: #selector(NoteListTableView.delete(_:)))))
    }

    func testCopyAndDeleteAreEnabledWithASelection() {
        store.add(text: "a", sourceApp: nil)
        selection.selectSingle(store.notes[0].id)

        XCTAssertTrue(tableView.validateUserInterfaceItem(item(for: #selector(NoteListTableView.copy(_:)))))
        XCTAssertTrue(tableView.validateUserInterfaceItem(item(for: #selector(NoteListTableView.delete(_:)))))
    }

    func testUnrelatedSelectorFallsThroughToRespondsTo() {
        // `selectAll(_:)` is implemented on the table regardless of selection.
        XCTAssertTrue(tableView.validateUserInterfaceItem(item(for: #selector(NoteListTableView.selectAll(_:)))))
    }

    // MARK: - deleteSelection

    func testDeleteSelectionRemovesTheSelectedNote() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)
        selection.selectSingle(ids[0])

        coordinator.deleteSelection()

        XCTAssertEqual(store.notes.map(\.id), [ids[1]])
    }

    func testDeleteSelectionInTheLogbookRoutesToConfirmationInsteadOfDeleting() {
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id
        store.toggleDone(ids: [id])
        store.clearDone()
        selection.setShowingLogbook(true)
        selection.selectSingle(id)

        coordinator.deleteSelection()

        XCTAssertEqual(selection.permanentDeleteConfirmation, [id])
        XCTAssertEqual(store.notes.count, 1, "nothing is deleted until the confirmation is answered")
    }
}
