import AppKit
import XCTest
@testable import Nickel

final class NoteContextMenuTests: XCTestCase {
    private var tempDirectory: URL!
    private var fileURL: URL!
    private var store: NoteStore!
    private var selection: SelectionModel!
    private var actions: PanelActions!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileURL = tempDirectory.appendingPathComponent("notes.json")
        store = NoteStore(fileURL: fileURL)
        selection = SelectionModel(store: store)
        actions = PanelActions(store: store, selection: selection)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        actions = nil
        selection = nil
        store = nil
        tempDirectory = nil
        fileURL = nil
        super.tearDown()
    }

    private func notesMenu() -> NSMenu {
        NoteContextMenu.menu(mode: .notes, store: store, selection: selection, actions: actions)
    }

    private func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    // MARK: - Selection-count-gated items

    func testEditAndEditInNewWindowAreEnabledOnlyWithExactlyOneSelected() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectedIDs = []
        XCTAssertEqual(item(notesMenu(), "Edit")?.isEnabled, false)
        XCTAssertEqual(item(notesMenu(), "Edit in New Window")?.isEnabled, false)

        selection.selectedIDs = [ids[0]]
        XCTAssertEqual(item(notesMenu(), "Edit")?.isEnabled, true)
        XCTAssertEqual(item(notesMenu(), "Edit in New Window")?.isEnabled, true)

        selection.selectedIDs = Set(ids)
        XCTAssertEqual(item(notesMenu(), "Edit")?.isEnabled, false)
        XCTAssertEqual(item(notesMenu(), "Edit in New Window")?.isEnabled, false)
    }

    func testMergeIsEnabledOnlyAtTwoOrMoreSelected() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectedIDs = []
        XCTAssertEqual(item(notesMenu(), "Merge Notes")?.isEnabled, false)

        selection.selectedIDs = [ids[0]]
        XCTAssertEqual(item(notesMenu(), "Merge Notes")?.isEnabled, false)

        selection.selectedIDs = [ids[0], ids[1]]
        XCTAssertEqual(item(notesMenu(), "Merge Notes")?.isEnabled, true)

        selection.selectedIDs = Set(ids)
        XCTAssertEqual(item(notesMenu(), "Merge Notes")?.isEnabled, true)
    }

    func testToggleExpandedIsEnabledOnlyWithANonEmptySelection() {
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id

        selection.selectedIDs = []
        XCTAssertEqual(item(notesMenu(), "Expand")?.isEnabled, false)

        selection.selectedIDs = [id]
        XCTAssertEqual(item(notesMenu(), "Expand")?.isEnabled, true)
    }

    // MARK: - Mark as Done / Not Done title

    func testToggleDoneTitleReflectsSelectionState() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)

        // Nothing selected: `allSelectedAreDone` is false, so the title
        // reads as an offer to mark done.
        selection.selectedIDs = []
        XCTAssertNotNil(item(notesMenu(), "Mark as Done"))
        XCTAssertNil(item(notesMenu(), "Mark as Not Done"))

        selection.selectedIDs = [ids[0]]
        XCTAssertNotNil(item(notesMenu(), "Mark as Done"), "not-yet-done selection reads as an offer to mark done")

        store.toggleDone(ids: [ids[0]])
        XCTAssertNotNil(item(notesMenu(), "Mark as Not Done"), "an all-done selection flips the title")
        XCTAssertNil(item(notesMenu(), "Mark as Done"))

        // Mixed done state: back to "Mark as Done".
        selection.selectedIDs = Set(ids)
        XCTAssertNotNil(item(notesMenu(), "Mark as Done"))
        XCTAssertNil(item(notesMenu(), "Mark as Not Done"))
    }

    // MARK: - Move submenu

    func testMoveSubmenuListsEverySectionPlusNoSection() {
        store.createSection(named: "Work")
        store.createSection(named: "Home")
        store.add(text: "a", sourceApp: nil)

        let moveItem = item(notesMenu(), "Move to Section")
        let submenuTitles = moveItem?.submenu?.items.map(\.title) ?? []

        XCTAssertEqual(submenuTitles, ["Work", "Home", "No Section", NSMenuItem.separator().title, "New Section with Selection"])
    }

    func testMoveSubmenuWithNoSectionsListsOnlyNoSectionAndNewSection() {
        store.add(text: "a", sourceApp: nil)

        let moveItem = item(notesMenu(), "Move to Section")
        let submenuTitles = moveItem?.submenu?.items.map(\.title) ?? []

        XCTAssertEqual(submenuTitles, ["No Section", NSMenuItem.separator().title, "New Section with Selection"])
    }

    // MARK: - Logbook mode

    func testLogbookMenuOffersPutBackAndDeletePermanently() {
        let menu = NoteContextMenu.menu(mode: .logbook, store: store, selection: selection, actions: actions)
        XCTAssertEqual(menu.items.map(\.title), ["Put Back", NSMenuItem.separator().title, "Delete Permanently"])
        XCTAssertTrue(menu.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled), "the Logbook menu has no selection-count gating")
    }

    func testLogbookMenuDoesNotOfferNotesModeOnlyItems() {
        let menu = NoteContextMenu.menu(mode: .logbook, store: store, selection: selection, actions: actions)
        for title in ["Copy", "Edit", "Merge Notes", "Move to Section", "Move to Logbook", "Delete"] {
            XCTAssertNil(item(menu, title), "\"\(title)\" is a Notes-mode item and shouldn't appear in the Logbook menu")
        }
    }

    // MARK: - Static builder is inspectable without a running app

    func testNotesMenuListsExpectedItemsInOrder() {
        let titles = notesMenu().items.map(\.title)
        XCTAssertEqual(titles, [
            "Copy",
            "Copy as List",
            NSMenuItem.separator().title,
            "Mark as Done",
            "Expand",
            "Edit",
            "Edit in New Window",
            "Merge Notes",
            "Move to Section",
            NSMenuItem.separator().title,
            "Move to Logbook",
            "Delete"
        ])
    }
}
