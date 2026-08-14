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

    // MARK: - Click handling

    func testPlainClickSelectsSingleThenReplacesOnAnother() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let idA = store.notes[0].id
        let idB = store.notes[1].id

        selection.handleClick(on: idA, shift: false, command: false)
        XCTAssertEqual(selection.selectedIDs, [idA])

        selection.handleClick(on: idB, shift: false, command: false)
        XCTAssertEqual(selection.selectedIDs, [idB])
    }

    func testCommandClickTogglesMembershipWithoutClearingOthers() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        let idA = store.notes[0].id
        let idB = store.notes[1].id
        let idC = store.notes[2].id

        selection.handleClick(on: idA, shift: false, command: false)
        selection.handleClick(on: idB, shift: false, command: true)
        XCTAssertEqual(selection.selectedIDs, [idA, idB])

        selection.handleClick(on: idC, shift: false, command: true)
        XCTAssertEqual(selection.selectedIDs, [idA, idB, idC])

        // Toggling an already-selected note removes only it.
        selection.handleClick(on: idB, shift: false, command: true)
        XCTAssertEqual(selection.selectedIDs, [idA, idC])
    }

    func testShiftClickWithAnchorSelectsInclusiveRangeAndExtendsFromSameAnchor() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        store.add(text: "d", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.handleClick(on: ids[1], shift: false, command: false) // anchor at index 1
        selection.handleClick(on: ids[3], shift: true, command: false)
        XCTAssertEqual(selection.selectedIDs, Set(ids[1...3]))

        // A further shift-click extends from the *same* anchor (index 1), not from index 3.
        selection.handleClick(on: ids[0], shift: true, command: false)
        XCTAssertEqual(selection.selectedIDs, Set(ids[0...1]))
    }

    func testShiftClickWithNoPriorAnchorBehavesAsSelectSingle() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let idB = store.notes[1].id

        selection.handleClick(on: idB, shift: true, command: false)
        XCTAssertEqual(selection.selectedIDs, [idB])
    }

    // MARK: - Keyboard navigation

    func testMoveSelectionStepsDownAndClampsAtLastNote() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectSingle(ids[0])

        selection.moveSelection(direction: 1, extend: false)
        XCTAssertEqual(selection.selectedIDs, [ids[1]])

        selection.moveSelection(direction: 1, extend: false)
        XCTAssertEqual(selection.selectedIDs, [ids[2]])

        // Already at the last note: repeated calls don't wrap.
        selection.moveSelection(direction: 1, extend: false)
        XCTAssertEqual(selection.selectedIDs, [ids[2]])
    }

    func testMoveSelectionExtendGrowsPastAnchorsImmediateNeighborOnRepeatedCalls() {
        // Regression for the `leadID` behavior described at SelectionModel.swift:65-69:
        // repeated shift-arrows must keep growing the range, not snap back to
        // just the anchor's immediate neighbor each time.
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        store.add(text: "d", sourceApp: nil)
        store.add(text: "e", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectSingle(ids[2]) // anchor = ids[2]

        selection.moveSelection(direction: 1, extend: true)
        XCTAssertEqual(selection.selectedIDs, Set(ids[2...3]))

        selection.moveSelection(direction: 1, extend: true)
        XCTAssertEqual(selection.selectedIDs, Set(ids[2...4]))
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

        selection.handleClick(on: idA, shift: false, command: false)
        selection.handleClick(on: idB, shift: false, command: true)
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

    // MARK: - Keyboard reveal (scroll-into-view)

    func testMoveSelectionSetsRevealRequestToNewLeadID() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectSingle(ids[0])
        XCTAssertNil(selection.revealRequest)

        selection.moveSelection(direction: 1, extend: false)
        XCTAssertEqual(selection.revealRequest?.id, ids[1])
    }

    func testRepeatedMoveSelectionCallsProduceDistinctTokens() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectSingle(ids[0])

        selection.moveSelection(direction: 1, extend: false)
        let firstRequest = selection.revealRequest

        selection.moveSelection(direction: 1, extend: false)
        let secondRequest = selection.revealRequest

        XCTAssertNotEqual(firstRequest, secondRequest)
        XCTAssertEqual(firstRequest?.id, ids[1])
        XCTAssertEqual(secondRequest?.id, ids[2])
    }

    func testMoveSelectionAtBoundaryStillRaisesRevealRequestForUnchangedLead() {
        // Design choice: a boundary move (already at the last/first row)
        // still raises a fresh `revealRequest` for the unchanged lead, so a
        // row that scrolled out of view by some other means (e.g. a panel
        // resize) gets pulled back on screen. `ScrollViewReader.scrollTo` is
        // a no-op when the row's already visible, so this is harmless.
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectSingle(ids[1]) // already at the last note

        selection.moveSelection(direction: 1, extend: false)

        XCTAssertEqual(selection.selectedIDs, [ids[1]])
        XCTAssertEqual(selection.revealRequest?.id, ids[1])
    }

    func testMoveSelectionWithNoSelectionRevealsTheEntryRow() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.moveSelection(direction: -1, extend: false)

        XCTAssertEqual(selection.selectedIDs, [ids[1]])
        XCTAssertEqual(selection.revealRequest?.id, ids[1])
    }

    func testMoveSelectionExtendAlsoSetsRevealRequestToLead() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectSingle(ids[0])
        selection.moveSelection(direction: 1, extend: true)

        XCTAssertEqual(selection.revealRequest?.id, ids[1])
    }

    func testClickDoesNotSetRevealRequest() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        let idA = store.notes[0].id
        let idB = store.notes[1].id

        selection.handleClick(on: idA, shift: false, command: false)
        selection.handleClick(on: idB, shift: false, command: false)
        selection.handleClick(on: idB, shift: true, command: false)
        selection.toggle(idA)

        XCTAssertNil(selection.revealRequest)
    }

    func testSelectAllDoesNotSetRevealRequest() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)

        selection.selectAllNotes()

        XCTAssertNil(selection.revealRequest)
    }

    // MARK: - Select all

    func testSelectAllNotesSelectsEverythingWithAnchorFirstAndLeadLast() {
        store.add(text: "a", sourceApp: nil)
        store.add(text: "b", sourceApp: nil)
        store.add(text: "c", sourceApp: nil)
        let ids = store.notes.map(\.id)

        selection.selectAllNotes()
        XCTAssertEqual(selection.selectedIDs, Set(ids))

        // lead should be the last note: extending down from here should
        // clamp in place (already at the end), proving lead == ids.last.
        selection.moveSelection(direction: 1, extend: true)
        XCTAssertEqual(selection.selectedIDs, Set(ids))

        // anchor should be the first note: extending up all the way should
        // select the full range down to (and including) the anchor.
        selection.moveSelection(direction: -1, extend: true)
        XCTAssertEqual(selection.selectedIDs, Set(ids[0...(ids.count - 2)]))
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
