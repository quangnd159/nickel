import Foundation

/// One row of the note list's `NSTableView`, in display order. Notes, section
/// headers, Logbook day headers and the Logbook footer all live in the same
/// flat row model, which is what lets the table animate a note moving between
/// sections as a plain row removal + insertion.
///
/// Every case carries a value that is unique within one list (note ids are
/// unique, section names are unique, a day appears once), so the enum itself
/// is a stable identity — that's what `NoteListDiff` diffs on.
enum NoteListRow: Hashable {
    case note(UUID)
    case sectionHeader(String)
    case dayHeader(Date)
    case logbookFooter

    var noteID: UUID? {
        if case .note(let id) = self { return id }
        return nil
    }

    /// Only note rows are selectable; headers and the footer are group rows.
    var isSelectable: Bool { noteID != nil }
}

/// Builds the flat row model the table renders, from the same filtered,
/// grouped notes `SelectionModel` derives `visibleOrder` from — so the note
/// rows and `visibleOrder` are always the same sequence (asserted by test).
enum NoteListRows {
    static func rows(store: NoteStore, selection: SelectionModel) -> [NoteListRow] {
        if selection.isShowingLogbook {
            return logbookRows(selection.filteredNotes)
        }

        if let activeSection = store.activeSection {
            return selection.notes(in: activeSection).map { .note($0.id) }
        }

        // Show All: ungrouped notes first, then every section's header —
        // including empty ones, which is where Show All is the only place they
        // can be found, reordered or deleted — followed by its notes.
        let grouped = selection.filteredNotesBySection
        var rows: [NoteListRow] = (grouped[String?.none] ?? []).map { .note($0.id) }
        for sectionName in store.sections {
            rows.append(.sectionHeader(sectionName))
            rows += (grouped[sectionName] ?? []).map { .note($0.id) }
        }
        return rows
    }

    /// The Logbook's rows: one day header per day cleared, its notes, and a
    /// single trailing footer note. Empty when there's nothing archived (the
    /// Logbook's own empty state is drawn in SwiftUI instead of as a row).
    static func logbookRows(_ notes: [Note], calendar: Calendar = .current) -> [NoteListRow] {
        let groups = logbookGroups(notes, calendar: calendar)
        guard !groups.isEmpty else { return [] }
        var rows: [NoteListRow] = []
        for group in groups {
            rows.append(.dayHeader(group.day))
            rows += group.notes.map { .note($0.id) }
        }
        rows.append(.logbookFooter)
        return rows
    }

    /// Archived notes split into one group per day cleared, keeping the
    /// incoming (newest-cleared-first) order so the flat sequence of rows
    /// matches `SelectionModel.visibleOrder` exactly.
    static func logbookGroups(_ notes: [Note], calendar: Calendar = .current) -> [(day: Date, notes: [Note])] {
        var order: [Date] = []
        var notesByDay: [Date: [Note]] = [:]
        for note in notes {
            let day = calendar.startOfDay(for: note.archivedAt ?? note.createdAt)
            if notesByDay[day] == nil { order.append(day) }
            notesByDay[day, default: []].append(note)
        }
        return order.map { (day: $0, notes: notesByDay[$0] ?? []) }
    }
}

/// Turns one row model into the next as a set of row removals and insertions
/// the table can animate, keeping every row it can in place.
///
/// Rows that only *moved* (a note dragged into a section, a section reordered)
/// come out as a removal plus an insertion rather than an `NSTableView`
/// `moveRow` — the longest-increasing-subsequence pass below keeps that set as
/// small as possible, so a single moved note animates on its own and nothing
/// else in the list is touched.
enum NoteListDiff {
    struct Steps: Equatable {
        var removals: IndexSet
        var insertions: IndexSet

        var isEmpty: Bool { removals.isEmpty && insertions.isEmpty }
    }

    /// Applying `removals` to `old` (highest index first) and then
    /// `insertions` from `new` (lowest index first) yields exactly `new`.
    static func steps(from old: [NoteListRow], to new: [NoteListRow]) -> Steps {
        var newIndexByRow: [NoteListRow: Int] = [:]
        newIndexByRow.reserveCapacity(new.count)
        for (index, row) in new.enumerated() {
            newIndexByRow[row] = index
        }

        // Old rows that still exist, paired with where they now sit. Keeping
        // the longest run of these whose new positions are already in
        // ascending order is the largest set that can stay put.
        var survivingOldIndices: [Int] = []
        var survivingNewIndices: [Int] = []
        for (oldIndex, row) in old.enumerated() {
            guard let newIndex = newIndexByRow[row] else { continue }
            survivingOldIndices.append(oldIndex)
            survivingNewIndices.append(newIndex)
        }

        let keptPositions = longestIncreasingSubsequence(survivingNewIndices)
        var keptOldIndices = Set<Int>()
        var keptNewIndices = Set<Int>()
        for position in keptPositions {
            keptOldIndices.insert(survivingOldIndices[position])
            keptNewIndices.insert(survivingNewIndices[position])
        }

        var removals = IndexSet()
        for index in old.indices where !keptOldIndices.contains(index) {
            removals.insert(index)
        }
        var insertions = IndexSet()
        for index in new.indices where !keptNewIndices.contains(index) {
            insertions.insert(index)
        }
        return Steps(removals: removals, insertions: insertions)
    }

    /// Positions (indices into `values`) of one longest strictly-increasing
    /// subsequence. Patience sorting with parent links — O(n log n), and n
    /// here is a panel's worth of rows.
    private static func longestIncreasingSubsequence(_ values: [Int]) -> [Int] {
        guard !values.isEmpty else { return [] }

        var tailPositions: [Int] = []
        var parents = [Int](repeating: -1, count: values.count)

        for position in values.indices {
            let value = values[position]
            var low = 0
            var high = tailPositions.count
            while low < high {
                let mid = (low + high) / 2
                if values[tailPositions[mid]] < value {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            if low > 0 { parents[position] = tailPositions[low - 1] }
            if low == tailPositions.count {
                tailPositions.append(position)
            } else {
                tailPositions[low] = position
            }
        }

        var result: [Int] = []
        var cursor = tailPositions[tailPositions.count - 1]
        while cursor != -1 {
            result.append(cursor)
            cursor = parents[cursor]
        }
        return result.reversed()
    }
}
