import XCTest
@testable import Nickel

/// The note list's row model and the diff the table animates it with — the
/// headlessly testable half of the `NSTableView` list. (The table view itself
/// needs a real window and is manual-test territory.)
final class NoteListRowsTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: NoteStore!
    private var selection: SelectionModel!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = NoteStore(fileURL: tempDirectory.appendingPathComponent("notes.json"))
        selection = SelectionModel(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        selection = nil
        store = nil
        tempDirectory = nil
        super.tearDown()
    }

    private var rows: [NoteListRow] {
        NoteListRows.rows(store: store, selection: selection)
    }

    // MARK: - Row model

    /// The contract that keeps keyboard navigation, ⌘A and every
    /// `PanelActions` command lined up with what's on screen: the table's note
    /// rows are `visibleOrder`, in order.
    func testNoteRowsMatchVisibleOrderInShowAll() {
        store.createSection(named: "Work")
        store.setActiveSection(nil)
        store.add(text: "loose", sourceApp: nil)
        store.setActiveSection("Work")
        store.add(text: "in work", sourceApp: nil)
        store.setActiveSection(nil)

        XCTAssertEqual(rows.compactMap(\.noteID), selection.visibleOrder)
    }

    func testNoteRowsMatchVisibleOrderInsideASection() {
        store.createSection(named: "Work")
        store.add(text: "in work", sourceApp: nil)

        XCTAssertEqual(rows.compactMap(\.noteID), selection.visibleOrder)
    }

    func testShowAllPutsUngroupedNotesFirstThenEachSectionsHeaderAndNotes() {
        store.createSection(named: "Work")
        store.setActiveSection(nil)
        store.add(text: "loose", sourceApp: nil)
        let looseID = store.notes[0].id
        store.setActiveSection("Work")
        store.add(text: "in work", sourceApp: nil)
        let workID = store.notes[1].id
        store.setActiveSection(nil)

        XCTAssertEqual(rows, [.note(looseID), .sectionHeader("Work"), .note(workID)])
    }

    /// Show All is the only place an empty section can be found, reordered or
    /// deleted, so its header has to render with no notes under it.
    func testEmptySectionStillGetsAHeaderRowInShowAll() {
        store.createSection(named: "Empty")
        store.setActiveSection(nil)

        XCTAssertEqual(rows, [.sectionHeader("Empty")])
    }

    func testFocusedSectionShowsOnlyItsNotesAndNoHeaderRow() {
        store.createSection(named: "Work")
        store.add(text: "in work", sourceApp: nil)
        let workID = store.notes[0].id
        store.setActiveSection(nil)
        store.add(text: "loose", sourceApp: nil)
        store.setActiveSection("Work")

        // The focused section's header is pinned above the list, not a row.
        XCTAssertEqual(rows, [.note(workID)])
    }

    func testSearchFilterNarrowsTheRows() {
        store.add(text: "apple", sourceApp: nil)
        store.add(text: "banana", sourceApp: nil)
        let idApple = store.notes[0].id

        selection.searchText = "apple"
        XCTAssertEqual(rows, [.note(idApple)])

        selection.searchText = ""
        XCTAssertEqual(rows.count, 2)
    }

    // MARK: - Logbook rows

    func testLogbookRowsGroupByDayAndEndWithTheFooter() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let earlier = day.addingTimeInterval(-60 * 60 * 24 * 3)
        let first = archivedNote(text: "a", archivedAt: day)
        let second = archivedNote(text: "b", archivedAt: day.addingTimeInterval(60))
        let third = archivedNote(text: "c", archivedAt: earlier)

        let rows = NoteListRows.logbookRows([first, second, third])

        let calendar = Calendar.current
        XCTAssertEqual(rows, [
            .dayHeader(calendar.startOfDay(for: day)),
            .note(first.id),
            .note(second.id),
            .dayHeader(calendar.startOfDay(for: earlier)),
            .note(third.id),
            .logbookFooter,
        ])
    }

    func testAnEmptyLogbookHasNoRowsAtAllIncludingTheFooter() {
        XCTAssertTrue(NoteListRows.logbookRows([]).isEmpty)
    }

    private func archivedNote(text: String, archivedAt: Date) -> Note {
        Note(
            id: UUID(),
            text: text,
            listName: nil,
            isDone: true,
            createdAt: archivedAt,
            sourceApp: nil,
            archivedAt: archivedAt
        )
    }

    // MARK: - Diff

    private func assertStepsRebuild(
        _ old: [NoteListRow],
        _ new: [NoteListRow],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NoteListDiff.Steps {
        let steps = NoteListDiff.steps(from: old, to: new)
        var rebuilt = old
        for index in steps.removals.reversed() {
            rebuilt.remove(at: index)
        }
        for index in steps.insertions {
            rebuilt.insert(new[index], at: index)
        }
        XCTAssertEqual(rebuilt, new, "applying the steps must yield the new rows exactly", file: file, line: line)
        return steps
    }

    func testUnchangedRowsProduceNoSteps() {
        let a = NoteListRow.note(UUID())
        let b = NoteListRow.note(UUID())

        let steps = assertStepsRebuild([a, b], [a, b])

        XCTAssertTrue(steps.isEmpty)
    }

    func testAnInsertedNoteTouchesOnlyItsOwnRow() {
        let a = NoteListRow.note(UUID())
        let b = NoteListRow.note(UUID())
        let inserted = NoteListRow.note(UUID())

        let steps = assertStepsRebuild([a, b], [inserted, a, b])

        XCTAssertTrue(steps.removals.isEmpty)
        XCTAssertEqual(steps.insertions, IndexSet(integer: 0))
    }

    func testADeletedNoteTouchesOnlyItsOwnRow() {
        let a = NoteListRow.note(UUID())
        let b = NoteListRow.note(UUID())
        let c = NoteListRow.note(UUID())

        let steps = assertStepsRebuild([a, b, c], [a, c])

        XCTAssertEqual(steps.removals, IndexSet(integer: 1))
        XCTAssertTrue(steps.insertions.isEmpty)
    }

    /// A note moved into a section: only the moved row leaves and comes back,
    /// so every other row (and its cell, mid-edit or not) stays put.
    func testAMovedNoteIsTheOnlyRowRemovedAndReinserted() {
        let moved = NoteListRow.note(UUID())
        let stayA = NoteListRow.note(UUID())
        let header = NoteListRow.sectionHeader("Work")
        let stayB = NoteListRow.note(UUID())

        let steps = assertStepsRebuild(
            [moved, stayA, header, stayB],
            [stayA, header, moved, stayB]
        )

        XCTAssertEqual(steps.removals, IndexSet(integer: 0))
        XCTAssertEqual(steps.insertions, IndexSet(integer: 2))
    }

    func testReorderingTwoSectionsMovesTheSmallerOfThem() {
        let headerA = NoteListRow.sectionHeader("A")
        let noteA = NoteListRow.note(UUID())
        let headerB = NoteListRow.sectionHeader("B")

        let steps = assertStepsRebuild([headerA, noteA, headerB], [headerB, headerA, noteA])

        XCTAssertEqual(steps.removals, IndexSet(integer: 2))
        XCTAssertEqual(steps.insertions, IndexSet(integer: 0))
    }

    func testSwitchingToAWhollyDifferentListReplacesEveryRow() {
        let old = [NoteListRow.note(UUID()), .note(UUID())]
        let new = [NoteListRow.note(UUID())]

        let steps = assertStepsRebuild(old, new)

        XCTAssertEqual(steps.removals, IndexSet(integersIn: 0..<2))
        XCTAssertEqual(steps.insertions, IndexSet(integer: 0))
    }

    func testEmptyingTheListRemovesEveryRow() {
        let old = [NoteListRow.note(UUID()), .note(UUID())]

        let steps = assertStepsRebuild(old, [])

        XCTAssertEqual(steps.removals, IndexSet(integersIn: 0..<2))
        XCTAssertTrue(steps.insertions.isEmpty)
    }

    func testFillingAnEmptyListInsertsEveryRow() {
        let new = [NoteListRow.note(UUID()), .sectionHeader("Work")]

        let steps = assertStepsRebuild([], new)

        XCTAssertTrue(steps.removals.isEmpty)
        XCTAssertEqual(steps.insertions, IndexSet(integersIn: 0..<2))
    }
}
