import AppKit
import XCTest
@testable import Nickel

/// Translating a proposed drop into a destination. Pure, so the whole mapping
/// is testable without a drag session — only the gesture itself is manual.
final class NoteListDropTests: XCTestCase {
    // A Show All list: two ungrouped notes, then Work (two notes), then an
    // empty Later section.
    //
    //   0  note u1
    //   1  note u2
    //   2  header Work
    //   3  note w1
    //   4  note w2
    //   5  header Later
    private let u1 = UUID()
    private let u2 = UUID()
    private let w1 = UUID()
    private let w2 = UUID()

    private var showAllRows: [NoteListRow] {
        [.note(u1), .note(u2), .sectionHeader("Work"), .note(w1), .note(w2), .sectionHeader("Later")]
    }

    private func resolve(
        rows: [NoteListRow]? = nil,
        row: Int,
        operation: NSTableView.DropOperation = .above,
        mode: NoteListMode = .notes,
        activeSection: String? = nil,
        isFiltering: Bool = false,
        dragged: Set<UUID> = []
    ) -> NoteListDrop.Resolution {
        NoteListDrop.resolve(
            rows: rows ?? showAllRows,
            proposedRow: row,
            operation: operation,
            mode: mode,
            activeSection: activeSection,
            isFiltering: isFiltering,
            draggedIDs: dragged
        )
    }

    private func target(_ resolution: NoteListDrop.Resolution) -> NoteListDropTarget? {
        guard case .accept(_, _, let target) = resolution else { return nil }
        return target
    }

    // MARK: - Between rows

    func testDropAtTheVeryTopLandsAtTheStartOfTheUngroupedBlock() {
        XCTAssertEqual(target(resolve(row: 0)), NoteListDropTarget(section: nil, beforeID: u1))
    }

    func testDropBetweenUngroupedNotes() {
        XCTAssertEqual(target(resolve(row: 1)), NoteListDropTarget(section: nil, beforeID: u2))
    }

    /// The gap above a section header belongs to the block that just ended,
    /// not to the section the header opens.
    func testDropAboveASectionHeaderIsTheEndOfThePreviousBlock() {
        XCTAssertEqual(target(resolve(row: 2)), NoteListDropTarget(section: nil, beforeID: nil))
    }

    func testDropAboveALaterHeaderIsTheEndOfThePrecedingSection() {
        XCTAssertEqual(target(resolve(row: 5)), NoteListDropTarget(section: "Work", beforeID: nil))
    }

    func testDropBetweenNotesInsideASection() {
        XCTAssertEqual(target(resolve(row: 4)), NoteListDropTarget(section: "Work", beforeID: w2))
    }

    func testDropBelowTheLastRowLandsAtTheEndOfTheLastBlock() {
        XCTAssertEqual(target(resolve(row: 6)), NoteListDropTarget(section: "Later", beforeID: nil))
    }

    func testDropBelowTheLastRowWhenItIsANote() {
        let rows: [NoteListRow] = [.note(u1), .sectionHeader("Work"), .note(w1)]
        XCTAssertEqual(target(resolve(rows: rows, row: 3)), NoteListDropTarget(section: "Work", beforeID: nil))
    }

    // MARK: - Onto rows

    func testDropOntoASectionHeaderMovesIntoThatSectionAtItsEnd() {
        let resolution = resolve(row: 2, operation: .on)
        XCTAssertEqual(target(resolution), NoteListDropTarget(section: "Work", beforeID: nil))
        guard case .accept(let row, let operation, _) = resolution else { return XCTFail("rejected") }
        XCTAssertEqual(row, 2)
        XCTAssertEqual(operation, .on, "the header itself is the drop target, so it highlights")
    }

    /// The only way to reach a section with no notes to drop between.
    func testDropOntoAnEmptySectionsHeader() {
        XCTAssertEqual(target(resolve(row: 5, operation: .on)), NoteListDropTarget(section: "Later", beforeID: nil))
    }

    /// Notes aren't containers, so AppKit's proposed "on" becomes "above".
    func testDropOntoANoteIsRetargetedToAboveIt() {
        let resolution = resolve(row: 3, operation: .on)
        guard case .accept(let row, let operation, let target) = resolution else { return XCTFail("rejected") }
        XCTAssertEqual(row, 3)
        XCTAssertEqual(operation, .above)
        XCTAssertEqual(target, NoteListDropTarget(section: "Work", beforeID: w1))
    }

    // MARK: - A focused section

    func testInsideAFocusedSectionEveryDropStaysInThatSection() {
        let rows: [NoteListRow] = [.note(w1), .note(w2)]
        XCTAssertEqual(
            target(resolve(rows: rows, row: 1, activeSection: "Work")),
            NoteListDropTarget(section: "Work", beforeID: w2)
        )
        XCTAssertEqual(
            target(resolve(rows: rows, row: 2, activeSection: "Work")),
            NoteListDropTarget(section: "Work", beforeID: nil)
        )
    }

    // MARK: - While filtering

    /// Positions between rows mean nothing in a filtered list: the note above
    /// the gap on screen isn't the note above it in the list.
    func testFilteringRejectsDropsBetweenRows() {
        XCTAssertEqual(resolve(row: 1, isFiltering: true), .reject)
        XCTAssertEqual(resolve(row: 6, isFiltering: true), .reject)
    }

    /// A whole-section drop is still unambiguous, so it stays available.
    func testFilteringStillAllowsDropsOntoASectionHeader() {
        XCTAssertEqual(
            target(resolve(row: 2, operation: .on, isFiltering: true)),
            NoteListDropTarget(section: "Work", beforeID: nil)
        )
    }

    func testFilteringRejectsADropOntoANoteSinceItBecomesAPositionalDrop() {
        XCTAssertEqual(resolve(row: 3, operation: .on, isFiltering: true), .reject)
    }

    // MARK: - Refusals

    func testTheLogbookRefusesEveryDrop() {
        let rows: [NoteListRow] = [.dayHeader(Date()), .note(u1), .logbookFooter]
        for row in 0...3 {
            XCTAssertEqual(resolve(rows: rows, row: row, mode: .logbook), .reject, "row \(row)")
            XCTAssertEqual(resolve(rows: rows, row: row, operation: .on, mode: .logbook), .reject, "row \(row) on")
        }
    }

    /// Defensive: the Logbook's own rows are refused even if they somehow turn
    /// up in a list that allows drops.
    func testDayHeadersAndTheFooterAreNeverDropTargets() {
        let rows: [NoteListRow] = [.dayHeader(Date()), .note(u1), .logbookFooter]
        XCTAssertEqual(resolve(rows: rows, row: 0), .reject)
        XCTAssertEqual(resolve(rows: rows, row: 2), .reject)
    }

    func testDroppingOnTheDraggedNotesThemselvesIsRefused() {
        XCTAssertEqual(resolve(row: 1, dragged: [u2]), .reject)
        XCTAssertEqual(resolve(row: 3, dragged: [w1, w2]), .reject)
    }

    /// Dropping at the end of a block is still allowed while dragging from it:
    /// there's no `beforeID` to collide with, and the store settles a genuine
    /// no-op on its own.
    func testDroppingAtTheEndOfABlockIsAllowedWhileDraggingFromIt() {
        XCTAssertNotNil(target(resolve(row: 2, dragged: [u1])))
    }

    func testOutOfRangeRowsAreRefused() {
        XCTAssertEqual(resolve(row: 7), .reject)
        XCTAssertEqual(resolve(row: -1), .reject)
    }

    func testAnEmptyListAcceptsADropAtItsStart() {
        XCTAssertEqual(target(resolve(rows: [], row: 0)), NoteListDropTarget(section: nil, beforeID: nil))
    }
}
