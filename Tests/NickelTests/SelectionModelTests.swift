import XCTest
@testable import Nickel

final class SelectionModelTests: XCTestCase {
    private var tempDirectory: URL!
    private var fileURL: URL!
    private var store: NoteStore!
    private var selection: SelectionModel!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileURL = tempDirectory.appendingPathComponent("notes.json")
        store = NoteStore(fileURL: fileURL)
        selection = SelectionModel(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        selection = nil
        store = nil
        tempDirectory = nil
        fileURL = nil
        super.tearDown()
    }

    // MARK: - Search filtering vs. selection

    func testSelectionOfNoteHiddenByFilterSurvives() {
        store.add(text: "apple", sourceApp: nil)
        store.add(text: "banana", sourceApp: nil)
        let idBanana = store.notes[1].id

        selection.selectSingle(idBanana)
        XCTAssertEqual(selection.selectedIDs, [idBanana])

        selection.searchText = "apple"
        XCTAssertFalse(selection.visibleOrder.contains(idBanana))
        XCTAssertEqual(selection.selectedIDs, [idBanana], "selection should survive being hidden by a search filter")

        selection.searchText = ""
        XCTAssertTrue(selection.visibleOrder.contains(idBanana))
        XCTAssertEqual(selection.selectedIDs, [idBanana])
    }

    // MARK: - Pruning on deletion

    func testDeletingSelectedNotePrunesSelectionAndEndsEditing() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let idA = store.notes[0].id
        let idB = store.notes[1].id

        selection.selectedIDs = [idA, idB]
        selection.beginEditing(id: idA, text: "a")
        XCTAssertEqual(selection.editingID, idA)

        store.delete(ids: [idA])

        XCTAssertEqual(selection.selectedIDs, [idB])
        XCTAssertNil(selection.editingID)
        XCTAssertEqual(selection.editingText, "")
    }

    // MARK: - visibleOrder with sections

    func testVisibleOrderScopedToActiveSectionAndUngroupedFirstOtherwise() {
        store.createSection(named: "A")
        store.createSection(named: "B")
        store.setActiveSection(nil)
        store.add(text: "ungrouped", sourceApp: nil)
        let idUngrouped = store.notes[0].id

        store.setActiveSection("A")
        store.add(text: "in-a", sourceApp: nil)
        let idA = store.notes[1].id

        store.setActiveSection("B")
        store.add(text: "in-b", sourceApp: nil)
        let idB = store.notes[2].id

        store.setActiveSection("A")
        XCTAssertEqual(selection.visibleOrder, [idA])

        store.setActiveSection(nil)
        XCTAssertEqual(selection.visibleOrder, [idUngrouped, idA, idB])
    }

    // MARK: - Search filtering by attachment filename

    func testSearchMatchesAttachmentOnlyNoteByFilename() {
        store.add(text: "alpha", sourceApp: nil)

        let sourceURL = tempDirectory.appendingPathComponent("source-screenshot.png")
        try! Data().write(to: sourceURL)
        store.add(
            text: "",
            attachments: [(sourceURL: sourceURL, filename: "screenshot-beta.png", contentType: "public.png")],
            sourceApp: nil
        )
        let idAttachmentOnly = store.notes[1].id

        selection.searchText = "beta"

        XCTAssertEqual(selection.filteredNotes.map(\.id), [idAttachmentOnly])
        XCTAssertEqual(selection.visibleOrder, [idAttachmentOnly])
    }

    func testSearchStillMatchesTextWhenNoteHasAttachments() {
        let sourceURL = tempDirectory.appendingPathComponent("source-other.png")
        try! Data().write(to: sourceURL)
        store.add(
            text: "gamma",
            attachments: [(sourceURL: sourceURL, filename: "other.png", contentType: "public.png")],
            sourceApp: nil
        )
        let idGamma = store.notes[0].id

        selection.searchText = "gamma"

        XCTAssertEqual(selection.filteredNotes.map(\.id), [idGamma])
    }

    func testSearchMissesWhenNeitherTextNorFilenameMatch() {
        store.add(text: "alpha", sourceApp: nil)

        let sourceURL = tempDirectory.appendingPathComponent("source-beta.png")
        try! Data().write(to: sourceURL)
        store.add(
            text: "",
            attachments: [(sourceURL: sourceURL, filename: "beta.png", contentType: "public.png")],
            sourceApp: nil
        )

        selection.searchText = "zzz"

        XCTAssertTrue(selection.filteredNotes.isEmpty)
    }

    // MARK: - Reveal (scroll-into-view)
    //
    // Arrow-key navigation no longer raises a reveal request: `NSTableView`
    // keeps the lead row visible on its own. Expanding a row still does —
    // the row grows downward, so a note near the viewport bottom would
    // otherwise disclose its content off-screen.

    func testExpandingRevealsTheLastExpandedRow() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)

        XCTAssertNil(selection.revealRequest)

        selection.toggleExpanded(ids: [ids[0], ids[1]])

        XCTAssertEqual(selection.revealRequest?.id, ids[1])
    }

    func testRepeatedExpandsProduceDistinctRevealTokens() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.toggleExpanded(ids: [ids[0]])
        let firstRequest = selection.revealRequest

        selection.toggleExpanded(ids: [ids[1]])
        let secondRequest = selection.revealRequest

        XCTAssertNotEqual(firstRequest, secondRequest)
        XCTAssertEqual(firstRequest?.id, ids[0])
        XCTAssertEqual(secondRequest?.id, ids[1])
    }

    func testCollapsingDoesNotSetRevealRequest() {
        store.add(text: "a", sourceApp: nil)
        let id = store.notes[0].id

        selection.toggleExpanded(ids: [id])
        let afterExpand = selection.revealRequest

        selection.toggleExpanded(ids: [id])

        XCTAssertEqual(selection.revealRequest, afterExpand, "collapse only shrinks the row, so nothing needs revealing")
    }

    func testSelectAllDoesNotSetRevealRequest() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)

        selection.selectAllNotes()

        XCTAssertNil(selection.revealRequest)
    }

    // MARK: - Select all

    func testSelectAllNotesSelectsEveryVisibleNote() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectAllNotes()

        XCTAssertEqual(selection.selectedIDs, Set(ids))
    }

    func testSelectAllNotesIsScopedToWhatTheSearchFilterLeavesVisible() {
        store.add(text: "apple", sourceApp: nil)
        store.add(text: "banana", sourceApp: nil)
        let idApple = store.notes[0].id

        selection.searchText = "apple"
        selection.selectAllNotes()

        XCTAssertEqual(selection.selectedIDs, [idApple])
    }

    // MARK: - Logbook

    func testArchivedNotesAreExcludedFromTheListAndShownInTheLogbook() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let idA = store.notes[0].id
        let idB = store.notes[1].id
        store.toggleDone(ids: [idA])
        store.clearDone()

        XCTAssertEqual(selection.filteredNotes.map(\.id), [idB])
        XCTAssertEqual(selection.visibleOrder, [idB])

        selection.setShowingLogbook(true)

        XCTAssertEqual(selection.filteredNotes.map(\.id), [idA])
        XCTAssertEqual(selection.visibleOrder, [idA])
    }

    func testClearingDoneDropsTheArchivedNoteFromTheSelection() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let idA = store.notes[0].id
        let idB = store.notes[1].id
        store.toggleDone(ids: [idA])
        selection.selectAllNotes()

        store.clearDone()

        XCTAssertEqual(selection.selectedIDs, [idB])
    }

    func testSwitchingToTheLogbookClearsTheSelection() {
        store.add(text: "a", sourceApp: nil)
        selection.selectAllNotes()

        selection.setShowingLogbook(true)

        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertTrue(selection.isShowingLogbook)
    }

    // MARK: - Active section changes clear the selection

    /// A selection is scoped to whatever's on screen; switching the active
    /// section (however it happens — ⇧⌘]/⇧⌘[, the ⋯ menu, a ⌘K switch, "Show
    /// All") must drop a selection that no longer belongs to the visible
    /// list. Covers `store.setActiveSection` directly, the entry point every
    /// other section switch funnels through (see `NoteStore.cycleActiveSection`).
    func testSettingActiveSectionClearsTheSelection() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        selection.selectAllNotes()
        XCTAssertFalse(selection.selectedIDs.isEmpty)

        store.setActiveSection("Work")

        XCTAssertTrue(selection.selectedIDs.isEmpty)
    }

    /// `cycleActiveSection` (⇧⌘]/⇧⌘[, the View menu's Next/Previous Section)
    /// is implemented in terms of `setActiveSection`, so it must clear the
    /// selection the same way.
    func testCyclingActiveSectionClearsTheSelection() {
        store.createSection(named: "Work")
        store.add(text: "a", sourceApp: nil)
        selection.selectAllNotes()
        XCTAssertFalse(selection.selectedIDs.isEmpty)

        store.cycleActiveSection(direction: 1)

        XCTAssertTrue(selection.selectedIDs.isEmpty)
    }

    /// Re-selecting the section that's already active is a no-op for
    /// `NoteStore` in the sense that nothing else changes, but `activeSection`
    /// still republishes — selection still clears, which is harmless (there's
    /// nothing left to preserve a selection *for* once the palette or menu
    /// interaction that triggered it has committed).
    func testSettingActiveSectionToItsCurrentValueStillClearsSelection() {
        store.add(text: "a", sourceApp: nil)
        selection.selectAllNotes()
        XCTAssertFalse(selection.selectedIDs.isEmpty)

        store.setActiveSection(nil) // already nil (Show All)

        XCTAssertTrue(selection.selectedIDs.isEmpty)
    }
}
