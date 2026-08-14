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

    // MARK: - Empty sections, reached by the gap below their header

    /// A section with no notes has no gaps of its own, so the one directly
    /// below its header — which is the gap above whatever follows — is how it's
    /// reached. Here "Later" is empty and last, so that gap is the end of the
    /// list.
    func testAnEmptySectionAtTheEndIsReachedByTheGapBelowItsHeader() {
        XCTAssertEqual(target(resolve(row: 6)), NoteListDropTarget(section: "Later", beforeID: nil))
    }

    /// Two empty sections in a row: each header's following gap belongs to that
    /// header's own section, not to the block before them both.
    func testConsecutiveEmptySectionsEachGetTheirOwnGap() {
        let c1 = UUID()
        let rows: [NoteListRow] = [
            .note(u1),              // 0
            .sectionHeader("A"),    // 1  empty
            .sectionHeader("B"),    // 2  empty
            .sectionHeader("C"),    // 3
            .note(c1),              // 4
        ]
        // Above A's header: still the ungrouped block.
        XCTAssertEqual(target(resolve(rows: rows, row: 1)), NoteListDropTarget(section: nil, beforeID: nil))
        // Below A's header (= above B's): into A.
        XCTAssertEqual(target(resolve(rows: rows, row: 2)), NoteListDropTarget(section: "A", beforeID: nil))
        // Below B's header (= above C's): into B.
        XCTAssertEqual(target(resolve(rows: rows, row: 3)), NoteListDropTarget(section: "B", beforeID: nil))
        // Below C's header: the start of C, in front of its first note.
        XCTAssertEqual(target(resolve(rows: rows, row: 4)), NoteListDropTarget(section: "C", beforeID: c1))
        // Past the end: the end of C.
        XCTAssertEqual(target(resolve(rows: rows, row: 5)), NoteListDropTarget(section: "C", beforeID: nil))
    }

    /// The gap below a non-empty section's header is the start of that section,
    /// in front of its first note — not the end of the block above.
    func testTheGapBelowANonEmptySectionsHeaderIsThatSectionsStart() {
        XCTAssertEqual(target(resolve(row: 3)), NoteListDropTarget(section: "Work", beforeID: w1))
    }

    // MARK: - Nothing is an on-row target

    /// Not notes, and not section headers either: every drop lands in a gap.
    func testAProposedOnRowDropBecomesADropAboveThatRow() {
        for row in [0, 2, 3, 5] {
            let resolution = resolve(row: row, operation: .on)
            guard case .accept(let targetRow, let operation, let dropTarget) = resolution else {
                return XCTFail("row \(row) rejected")
            }
            XCTAssertEqual(targetRow, row, "row \(row)")
            XCTAssertEqual(operation, .above, "row \(row)")
            XCTAssertEqual(dropTarget, target(resolve(row: row)), "row \(row) should match the .above result")
        }
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

    /// Every drop position is ambiguous in a filtered list — the note above a
    /// gap on screen isn't the note above it in the list — and since every drop
    /// is positional now, filtering refuses all of them.
    func testFilteringRejectsEveryDrop() {
        for row in 0...6 {
            XCTAssertEqual(resolve(row: row, isFiltering: true), .reject, "row \(row)")
            XCTAssertEqual(resolve(row: row, operation: .on, isFiltering: true), .reject, "row \(row) on")
        }
    }

    // MARK: - Refusals

    func testTheLogbookRefusesEveryDrop() {
        let rows: [NoteListRow] = [.dayHeader(Date(), isFirst: true), .note(u1), .logbookFooter]
        for row in 0...3 {
            XCTAssertEqual(resolve(rows: rows, row: row, mode: .logbook), .reject, "row \(row)")
            XCTAssertEqual(resolve(rows: rows, row: row, operation: .on, mode: .logbook), .reject, "row \(row) on")
        }
    }

    /// Defensive: the Logbook's own rows are refused even if they somehow turn
    /// up in a list that allows drops.
    func testDayHeadersAndTheFooterAreNeverDropTargets() {
        let rows: [NoteListRow] = [.dayHeader(Date(), isFirst: true), .note(u1), .logbookFooter]
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
