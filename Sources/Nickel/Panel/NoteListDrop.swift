import AppKit

extension NSPasteboard.PasteboardType {
    /// A dragged note, carried as its id. Private to Nickel: it's what makes a
    /// drag between the list's own rows a reorder rather than a text drop.
    /// Dragged rows also carry `.string`, so dropping a note into another app
    /// pastes its text.
    static let nickelNoteID = NSPasteboard.PasteboardType("com.nickel.note-id")
}

/// Where a drop lands, once the table's `(row, operation)` pair has been
/// translated out of screen positions into list terms.
struct NoteListDropTarget: Equatable {
    /// The destination section; `nil` is the ungrouped block.
    var section: String?
    /// The note the dropped notes land in front of, or `nil` for the end of
    /// that section's notes.
    var beforeID: UUID?
}

/// Translating a proposed drop into a target — the whole of the drag feature's
/// decision-making, kept pure so it can be tested without a drag session.
///
/// `validateDrop` and `acceptDrop` both resolve through here, so what the drop
/// indicator promises and what the store is told can't drift apart.
enum NoteListDrop {
    enum Resolution: Equatable {
        case reject
        /// Retarget the table to `row`/`operation` (which is what draws the
        /// indicator in the right place), and commit `target` on drop.
        case accept(row: Int, operation: NSTableView.DropOperation, target: NoteListDropTarget)
    }

    /// - Parameters:
    ///   - isFiltering: a search is narrowing the list. Positions between rows
    ///     mean nothing then — the note above the gap on screen isn't the note
    ///     above it in the list — so only whole-section drops stay available.
    ///   - draggedIDs: the notes being dragged, so a drop onto them is refused
    ///     rather than promised and then quietly ignored.
    static func resolve(
        rows: [NoteListRow],
        proposedRow: Int,
        operation: NSTableView.DropOperation,
        mode: NoteListMode,
        activeSection: String?,
        isFiltering: Bool,
        draggedIDs: Set<UUID>
    ) -> Resolution {
        // The Logbook is a record, not a list to arrange.
        guard mode == .notes else { return .reject }
        guard rows.indices.contains(proposedRow) || proposedRow == rows.count else { return .reject }

        if operation == .on {
            // Dropping onto a section header puts the notes in that section,
            // at its end. It's also the only way to reach a section with no
            // notes to drop between.
            if rows.indices.contains(proposedRow), case .sectionHeader(let name) = rows[proposedRow] {
                return .accept(
                    row: proposedRow,
                    operation: .on,
                    target: NoteListDropTarget(section: name, beforeID: nil)
                )
            }
            // Notes aren't containers: a drop onto one becomes a drop above it.
            return resolve(
                rows: rows,
                proposedRow: proposedRow,
                operation: .above,
                mode: mode,
                activeSection: activeSection,
                isFiltering: isFiltering,
                draggedIDs: draggedIDs
            )
        }

        guard !isFiltering else { return .reject }

        let target: NoteListDropTarget
        if proposedRow == rows.count {
            // Past the last row: the end of whatever block finishes the list.
            target = NoteListDropTarget(
                section: section(endingAt: rows.count - 1, in: rows, activeSection: activeSection),
                beforeID: nil
            )
        } else {
            switch rows[proposedRow] {
            case .note(let id):
                target = NoteListDropTarget(
                    section: section(endingAt: proposedRow, in: rows, activeSection: activeSection),
                    beforeID: id
                )
            case .sectionHeader:
                // The gap above a header belongs to the block that just ended.
                target = NoteListDropTarget(
                    section: section(endingAt: proposedRow - 1, in: rows, activeSection: activeSection),
                    beforeID: nil
                )
            case .dayHeader, .logbookFooter:
                return .reject
            }
        }

        // A drop at the front of the dragged notes themselves would move
        // nothing; refuse it so no indicator promises otherwise.
        if let beforeID = target.beforeID, draggedIDs.contains(beforeID) {
            return .reject
        }
        return .accept(row: proposedRow, operation: .above, target: target)
    }

    /// The section a row belongs to: the nearest section header at or above it,
    /// or the ungrouped block when there is none. With a section focused there
    /// are no headers and every row is in it.
    private static func section(endingAt row: Int, in rows: [NoteListRow], activeSection: String?) -> String? {
        if let activeSection { return activeSection }
        var index = min(row, rows.count - 1)
        while index >= 0 {
            if case .sectionHeader(let name) = rows[index] { return name }
            index -= 1
        }
        return nil
    }
}
