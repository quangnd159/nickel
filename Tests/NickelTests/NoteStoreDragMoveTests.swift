import XCTest
@testable import Nickel

/// `NoteStore.move(ids:toSection:before:)` — the mutation a drag-and-drop
/// reorder or cross-section move commits.
final class NoteStoreDragMoveTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: NoteStore!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = NoteStore(fileURL: tempDirectory.appendingPathComponent("notes.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        store = nil
        tempDirectory = nil
        super.tearDown()
    }

    /// Adds notes with the given texts, ungrouped, and returns their ids in
    /// the order added.
    @discardableResult
    private func addNotes(_ texts: [String]) -> [UUID] {
        for text in texts {
            store.add(text: text, sourceApp: nil)
        }
        return store.activeNotes.suffix(texts.count).map(\.id)
    }

    /// The visible order of a section's notes, by text.
    private func texts(inSection sectionName: String?) -> [String] {
        store.activeNotes.filter { $0.listName == sectionName }.map(\.text)
    }

    // MARK: - Reorder within a section

    func testReorderMovesANoteBeforeAnother() {
        let ids = addNotes(["a", "b", "c"])

        store.move(ids: [ids[2]], toSection: nil, before: ids[0])

        XCTAssertEqual(texts(inSection: nil), ["c", "a", "b"])
    }

    func testReorderToTheEndUsesANilBeforeID() {
        let ids = addNotes(["a", "b", "c"])

        store.move(ids: [ids[0]], toSection: nil, before: nil)

        XCTAssertEqual(texts(inSection: nil), ["b", "c", "a"])
    }

    func testReorderWithinAFocusedSectionLeavesOtherSectionsAlone() {
        store.createSection(named: "Work")
        store.setActiveSection(nil)
        addNotes(["loose"])
        store.setActiveSection("Work")
        let work = addNotes(["w1", "w2", "w3"])
        store.setActiveSection(nil)

        store.move(ids: [work[2]], toSection: "Work", before: work[0])

        XCTAssertEqual(texts(inSection: "Work"), ["w3", "w1", "w2"])
        XCTAssertEqual(texts(inSection: nil), ["loose"])
    }

    // MARK: - Across sections

    func testMovingAcrossSectionsLandsAtThePosition() {
        store.createSection(named: "Work")
        store.setActiveSection("Work")
        let work = addNotes(["w1", "w2"])
        store.setActiveSection(nil)
        let loose = addNotes(["loose"])

        store.move(ids: [loose[0]], toSection: "Work", before: work[1])

        XCTAssertEqual(texts(inSection: "Work"), ["w1", "loose", "w2"])
        XCTAssertTrue(texts(inSection: nil).isEmpty)
    }

    func testMovingAcrossSectionsToTheEnd() {
        store.createSection(named: "Work")
        store.setActiveSection("Work")
        addNotes(["w1", "w2"])
        store.setActiveSection(nil)
        let loose = addNotes(["loose"])

        store.move(ids: [loose[0]], toSection: "Work", before: nil)

        XCTAssertEqual(texts(inSection: "Work"), ["w1", "w2", "loose"])
    }

    /// Dropping onto a section header is how an empty section is targeted, and
    /// it arrives here as "end of that section", which has no notes to be
    /// after.
    func testMovingIntoAnEmptySection() {
        store.createSection(named: "Empty")
        store.setActiveSection(nil)
        let loose = addNotes(["a", "b"])

        store.move(ids: [loose[0]], toSection: "Empty", before: nil)

        XCTAssertEqual(texts(inSection: "Empty"), ["a"])
        XCTAssertEqual(texts(inSection: nil), ["b"])
    }

    func testMovingToAnUnknownSectionCreatesIt() {
        let ids = addNotes(["a"])
        XCTAssertFalse(store.sections.contains("Fresh"))

        store.move(ids: [ids[0]], toSection: "Fresh", before: nil)

        XCTAssertTrue(store.sections.contains("Fresh"))
        XCTAssertEqual(texts(inSection: "Fresh"), ["a"])
    }

    func testMovingBackToUngroupedClearsTheSection() {
        store.createSection(named: "Work")
        store.setActiveSection("Work")
        let work = addNotes(["w1"])
        store.setActiveSection(nil)
        let loose = addNotes(["a", "b"])

        store.move(ids: [work[0]], toSection: nil, before: loose[1])

        XCTAssertEqual(texts(inSection: nil), ["a", "w1", "b"])
        XCTAssertTrue(texts(inSection: "Work").isEmpty)
    }

    // MARK: - Multiple notes

    func testMultipleNotesKeepTheirRelativeOrder() {
        let ids = addNotes(["a", "b", "c", "d"])

        store.move(ids: [ids[0], ids[2]], toSection: nil, before: ids[3])

        XCTAssertEqual(texts(inSection: nil), ["b", "a", "c", "d"])
    }

    /// The dragged order is what's preserved, not the array order — dragging a
    /// selection built bottom-up must still land in visible order.
    func testMultipleNotesFollowTheOrderTheyWerePassedIn() {
        let ids = addNotes(["a", "b", "c"])

        store.move(ids: [ids[2], ids[0]], toSection: nil, before: ids[1])

        XCTAssertEqual(texts(inSection: nil), ["c", "a", "b"])
    }

    func testADraggedSetSpanningTwoSectionsCollapsesIntoTheTarget() {
        store.createSection(named: "Work")
        store.setActiveSection("Work")
        let work = addNotes(["w1", "w2"])
        store.setActiveSection(nil)
        let loose = addNotes(["l1", "l2"])

        store.move(ids: [loose[0], work[1]], toSection: nil, before: loose[1])

        XCTAssertEqual(texts(inSection: nil), ["l1", "w2", "l2"])
        XCTAssertEqual(texts(inSection: "Work"), ["w1"])
    }

    // MARK: - No-op drops

    func testDroppingANoteOnItselfChangesNothing() {
        let ids = addNotes(["a", "b", "c"])

        store.move(ids: [ids[1]], toSection: nil, before: ids[1])

        XCTAssertEqual(texts(inSection: nil), ["a", "b", "c"])
    }

    func testDroppingASelectionOnItsOwnFirstNoteChangesNothing() {
        let ids = addNotes(["a", "b", "c", "d"])

        store.move(ids: [ids[1], ids[2]], toSection: nil, before: ids[1])

        XCTAssertEqual(texts(inSection: nil), ["a", "b", "c", "d"])
    }

    func testAnEmptyDragIsANoOp() {
        addNotes(["a", "b"])

        store.move(ids: [], toSection: "Work", before: nil)

        XCTAssertEqual(texts(inSection: nil), ["a", "b"])
        XCTAssertFalse(store.sections.contains("Work"), "an empty move shouldn't create the section either")
    }

    func testUnknownIDsAreIgnored() {
        let ids = addNotes(["a", "b"])

        store.move(ids: [UUID(), ids[1]], toSection: nil, before: ids[0])

        XCTAssertEqual(texts(inSection: nil), ["b", "a"])
    }

    // MARK: - Archived notes share the array

    func testArchivedNotesSurviveAReorderIntact() {
        let ids = addNotes(["a", "b", "c"])
        store.toggleDone(ids: [ids[1]])
        store.clearDone()
        XCTAssertEqual(store.archivedNotes.map(\.text), ["b"])

        let live = store.activeNotes.map(\.id)
        store.move(ids: [live[1]], toSection: nil, before: live[0])

        XCTAssertEqual(texts(inSection: nil), ["c", "a"])
        XCTAssertEqual(store.archivedNotes.map(\.text), ["b"], "the Logbook's contents must be untouched")
        XCTAssertEqual(store.notes.count, 3, "nothing should be lost or duplicated")
    }

    /// "End of the section" has to mean the last *live* note in it: an
    /// archived note that still carries the section name isn't on screen, so
    /// landing after it would put the drop in the wrong place.
    func testEndOfSectionIgnoresArchivedNotesInThatSection() {
        store.createSection(named: "Work")
        store.setActiveSection("Work")
        let work = addNotes(["w1", "w2"])
        store.setActiveSection(nil)
        let loose = addNotes(["loose"])

        store.toggleDone(ids: [work[1]])
        store.clearDone()

        store.move(ids: [loose[0]], toSection: "Work", before: nil)

        XCTAssertEqual(texts(inSection: "Work"), ["w1", "loose"])
    }

    // MARK: - Persistence

    func testAReorderIsPersisted() {
        let ids = addNotes(["a", "b", "c"])
        store.move(ids: [ids[2]], toSection: nil, before: ids[0])
        store.saveNow()

        let reloaded = NoteStore(fileURL: tempDirectory.appendingPathComponent("notes.json"))

        XCTAssertEqual(reloaded.activeNotes.map(\.text), ["c", "a", "b"])
    }
}
