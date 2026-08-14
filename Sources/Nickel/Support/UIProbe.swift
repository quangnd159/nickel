import AppKit
import SwiftUI

/// A headless check of the note list's real geometry, for the parts of the
/// `NSTableView` list that can't be reached from `swift test`: row heights,
/// which row a point lands in, and whether a row's hosted content takes
/// clicks.
///
/// Enabled only by `NICKEL_UI_PROBE=1`, which `main.swift` checks *instead of*
/// starting the app normally — no status item, no hotkey monitor, no
/// Accessibility grant. It builds a real `FloatingPanel` over a throwaway
/// store, parks it off every screen, drives an edit the way a double-click
/// would, and asserts on what the table actually did. Exits 0 on success and
/// 1 on the first failed assertion, printing every row's frame either way.
///
/// Run it from the built debug binary:
///
///     swift build && NICKEL_UI_PROBE=1 .build/debug/Nickel
enum UIProbe {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["NICKEL_UI_PROBE"] == "1"
    }
}

/// Drives the probe once the app is up, then exits.
final class UIProbeDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var store: NoteStore?
    private var temporaryDirectory: URL?
    private var failures: [String] = []

    /// Long enough to wrap to many lines at the panel's width, so the
    /// collapsed 3-line preview and the full editor are obviously different
    /// heights. This is the case the whole probe exists for.
    private static let longNoteText = """
    This is a deliberately long note used by the UI probe. It has to wrap to \
    well over three lines at the panel's width so that the collapsed preview, \
    which is clamped to three lines, is much shorter than the inline editor \
    showing the whole thing. If the row does not grow when the editor opens, \
    the editor's text overflows the card, the selection outline is clipped, \
    and a click lands on the following row instead of in the text.
    """

    func applicationDidFinishLaunching(_ notification: Notification) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NickelUIProbe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory

        let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        store.add(text: "Short note above", sourceApp: nil)
        store.add(text: Self.longNoteText, sourceApp: nil)
        store.add(text: "Short note below", sourceApp: nil)
        self.store = store

        let panel = FloatingPanel(store: store)
        self.panel = panel
        // Parked far off every screen: the probe needs real layout, not a
        // window the user has to look at.
        panel.setFrame(NSRect(x: -20_000, y: -20_000, width: 360, height: 560), display: false)
        panel.orderFrontRegardless()
        self.panel = panel

        run(panel: panel, store: store)
    }

    // MARK: - The run

    private func run(panel: FloatingPanel, store: NoteStore) {
        settle()

        guard let table = findTable(in: panel) else {
            fail("no NoteListTableView in the panel's view tree")
            finish()
            return
        }
        let selection = panel.selectionModelForTesting

        let notes = store.activeNotes
        guard notes.count == 3 else {
            fail("expected 3 notes, found \(notes.count)")
            finish()
            return
        }
        let longNote = notes[1]
        let shortNote = notes[0]

        guard let longRow = rowIndex(of: longNote.id, in: table),
              let shortRow = rowIndex(of: shortNote.id, in: table) else {
            fail("could not map notes to rows (rowCount=\(table.numberOfRows))")
            finish()
            return
        }

        print("— collapsed —")
        dumpRows(table)
        let collapsedLongHeight = table.rect(ofRow: longRow).height
        let collapsedShortHeight = table.rect(ofRow: shortRow).height

        // (f) baseline sanity: the long note's collapsed row is the 3-line
        // clamp, so taller than a one-line note but nowhere near the editor.
        check(
            collapsedLongHeight > collapsedShortHeight,
            "collapsed long row (\(collapsedLongHeight)) should be taller than a short row (\(collapsedShortHeight))"
        )

        // (a) Beginning an edit grows the row. Same two calls the table's
        // double-click handler makes.
        selection.selectSingle(longNote.id)
        selection.beginEditing(id: longNote.id, text: longNote.text)
        settle()

        print("— editing —")
        dumpRows(table)
        let editingRect = table.rect(ofRow: longRow)
        check(
            editingRect.height > collapsedLongHeight + 20,
            "editing row should grow well past its collapsed height "
                + "(collapsed \(collapsedLongHeight), editing \(editingRect.height))"
        )

        // (b) A point in the editor's lower half belongs to the editing row,
        // not the row below it.
        let lowerHalf = NSPoint(x: editingRect.midX, y: editingRect.midY + editingRect.height / 4)
        let hitRow = table.row(at: lowerHalf)
        check(
            hitRow == longRow,
            "point in the editor's lower half should map to row \(longRow), got \(hitRow)"
        )

        // (c) The editing row's content takes clicks, so the caret can be
        // placed inside it.
        check(
            isCellInteractive(table: table, row: longRow) == true,
            "the editing row's hosting view should be hit-test interactive"
        )
        check(
            isCellInteractive(table: table, row: shortRow) == false,
            "a display row's hosting view should stay hit-test transparent"
        )

        // (f) An untouched display row keeps its height.
        check(
            table.rect(ofRow: shortRow).height == collapsedShortHeight,
            "a display row's height should not change (was \(collapsedShortHeight), now \(table.rect(ofRow: shortRow).height))"
        )

        // (d) Typing more lines grows the row further.
        selection.editingText = longNote.text + "\nan added line\nand another added line\nand a third added line"
        settle()

        print("— editing, more lines —")
        dumpRows(table)
        let grownHeight = table.rect(ofRow: longRow).height
        check(
            grownHeight > editingRect.height,
            "adding lines mid-edit should grow the row (\(editingRect.height) → \(grownHeight))"
        )

        // (e) Ending the edit shrinks it back to the collapsed preview.
        selection.endEditing()
        settle()

        print("— collapsed again —")
        dumpRows(table)
        let finalHeight = table.rect(ofRow: longRow).height
        check(
            abs(finalHeight - collapsedLongHeight) < 1,
            "ending the edit should restore the collapsed height "
                + "(expected \(collapsedLongHeight), got \(finalHeight))"
        )
        check(
            isCellInteractive(table: table, row: longRow) == false,
            "the row should stop taking clicks once the edit ends"
        )

        // (g) Expanding shows the note in full, which grows the row the same
        // way opening an edit does — the collapsed preview is clamped to three
        // lines.
        selection.toggleExpanded(ids: [longNote.id])
        settle()
        print("— expanded —")
        dumpRows(table)
        let expandedHeight = table.rect(ofRow: longRow).height
        check(
            expandedHeight > collapsedLongHeight,
            "expanding should grow the row past the 3-line preview "
                + "(collapsed \(collapsedLongHeight), expanded \(expandedHeight))"
        )

        selection.toggleExpanded(ids: [longNote.id])
        settle()
        check(
            abs(table.rect(ofRow: longRow).height - collapsedLongHeight) < 1,
            "collapsing should restore the preview height "
                + "(expected \(collapsedLongHeight), got \(table.rect(ofRow: longRow).height))"
        )

        // Reveal: a row near the bottom that grows past the viewport has to be
        // brought into view, by the least amount that does it, and the scroll
        // must never be left stranded past the end of the content.
        checkReveal(table: table, store: store, selection: selection)

        // (h) Section headers are group rows with their own, much smaller
        // content — they went through the same broken measurement.
        store.createSection(named: "Probe Section")
        store.setActiveSection(nil)
        settle()
        print("— with a section header —")
        dumpRows(table)
        if let headerRow = table.coordinator?.rows.firstIndex(of: .sectionHeader("Probe Section")) {
            let headerHeight = table.rect(ofRow: headerRow).height
            check(
                headerHeight > 0 && headerHeight < collapsedShortHeight,
                "a section header row should measure shorter than a note row "
                    + "(header \(headerHeight), note \(collapsedShortHeight))"
            )
        } else {
            fail("no section header row after creating a section")
        }

        finish()
    }

    // MARK: - Reveal

    /// Fills the list past the viewport, then checks that growing its last row
    /// scrolls it into view — minimally — and that shrinking it back doesn't
    /// leave the scroll position hanging past the content.
    private func checkReveal(table: NoteListTableView, store: NoteStore, selection: SelectionModel) {
        for index in 0..<12 {
            store.add(text: "Filler note \(index)", sourceApp: nil)
        }
        store.add(text: Self.longNoteText, sourceApp: nil)
        settle()

        guard let bottomNote = store.activeNotes.last,
              let bottomRow = table.coordinator?.rows.firstIndex(of: .note(bottomNote.id)) else {
            fail("could not find the bottom note's row")
            return
        }

        let clipView = table.enclosingScrollView?.contentView
        guard let clipView else {
            fail("the table has no enclosing scroll view")
            return
        }

        // Scroll to the very bottom so the last row is on screen but its
        // growth will run off the end.
        table.scrollRowToVisible(bottomRow)
        settle()
        print("— bottom row, before expanding —")
        print("  visible=\(clipView.documentVisibleRect)  row=\(table.rect(ofRow: bottomRow))")

        let beforeOrigin = clipView.documentVisibleRect.minY

        selection.toggleExpanded(ids: [bottomNote.id])
        settle()
        let expandedVisible = clipView.documentVisibleRect
        let expandedRow = table.rect(ofRow: bottomRow)
        print("— bottom row, expanded —")
        print("  visible=\(expandedVisible)  row=\(expandedRow)")

        check(
            expandedRow.maxY <= expandedVisible.maxY + 0.5,
            "the expanded row's bottom (\(expandedRow.maxY)) should be inside the visible rect "
                + "(ends \(expandedVisible.maxY))"
        )
        check(
            expandedVisible.minY > beforeOrigin,
            "expanding a bottom row should have scrolled down (was \(beforeOrigin), now \(expandedVisible.minY))"
        )

        selection.toggleExpanded(ids: [bottomNote.id])
        settle()
        let collapsedVisible = clipView.documentVisibleRect
        print("— bottom row, collapsed again —")
        print("  visible=\(collapsedVisible)  content=\(table.frame.height)")
        check(
            collapsedVisible.maxY <= table.frame.height + 0.5,
            "collapsing must not strand the scroll past the content "
                + "(visible ends \(collapsedVisible.maxY), content \(table.frame.height))"
        )

        // Beginning an edit on the bottom note must put the editor's end —
        // where the caret sits — on screen.
        selection.selectSingle(bottomNote.id)
        selection.beginEditing(id: bottomNote.id, text: bottomNote.text)
        settle()
        let editingVisible = clipView.documentVisibleRect
        let editingRow = table.rect(ofRow: bottomRow)
        print("— bottom row, editing —")
        print("  visible=\(editingVisible)  row=\(editingRow)")
        check(
            editingRow.maxY <= editingVisible.maxY + 0.5,
            "the editor's end (\(editingRow.maxY)) should be visible (viewport ends \(editingVisible.maxY))"
        )

        // A row already fully on screen needs no scroll at all.
        selection.endEditing()
        settle()
        guard let topNote = store.activeNotes.first,
              let topRow = table.coordinator?.rows.firstIndex(of: .note(topNote.id)) else { return }
        table.scrollRowToVisible(0)
        settle()
        let restingOrigin = clipView.documentVisibleRect.minY
        selection.selectSingle(topNote.id)
        selection.beginEditing(id: topNote.id, text: topNote.text)
        settle()
        check(
            abs(clipView.documentVisibleRect.minY - restingOrigin) < 0.5,
            "editing an already-visible top row should not scroll "
                + "(was \(restingOrigin), now \(clipView.documentVisibleRect.minY), row \(table.rect(ofRow: topRow)))"
        )
        selection.endEditing()
        settle()

        // ⌘E over several notes at once: the reveal follows the last one
        // affected, and lands minimally even though earlier rows resized too.
        let notes = store.activeNotes
        guard notes.count >= 2 else { return }
        let batch = Set(notes.suffix(2).map(\.id))
        table.scrollRowToVisible(0)
        settle()
        selection.toggleExpanded(ids: batch)
        settle()
        let batchVisible = clipView.documentVisibleRect
        let batchRow = table.rect(ofRow: bottomRow)
        print("— multi-expand —")
        print("  visible=\(batchVisible)  lastRow=\(batchRow)")
        check(
            batchRow.maxY <= batchVisible.maxY + 0.5,
            "expanding several notes should reveal the last one's bottom "
                + "(\(batchRow.maxY) vs viewport end \(batchVisible.maxY))"
        )
        selection.toggleExpanded(ids: batch)
        settle()
    }

    // MARK: - Harness plumbing

    /// Turns the main runloop long enough for SwiftUI to render, the hosting
    /// views to lay out, and any deferred row-height work to land.
    private func settle(seconds: TimeInterval = 0.6) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        panel?.contentView?.layoutSubtreeIfNeeded()
    }

    private func findTable(in panel: NSWindow) -> NoteListTableView? {
        guard let contentView = panel.contentView else { return nil }
        var queue: [NSView] = [contentView]
        while let view = queue.first {
            queue.removeFirst()
            if let table = view as? NoteListTableView { return table }
            queue += view.subviews
        }
        return nil
    }

    private func rowIndex(of noteID: UUID, in table: NoteListTableView) -> Int? {
        table.coordinator?.rows.firstIndex(of: .note(noteID))
    }

    private func isCellInteractive(table: NoteListTableView, row: Int) -> Bool? {
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteListCellView else {
            return nil
        }
        return cell.isContentInteractive
    }

    private func dumpRows(_ table: NoteListTableView) {
        for row in 0..<table.numberOfRows {
            let rect = table.rect(ofRow: row)
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteListCellView
            let fitting = cell.map { "\($0.fittingSize.height)" } ?? "—"
            let ideal = cell.map { "\($0.contentIdealHeight)" } ?? "—"
            print(String(
                format: "  row %d  y=%7.2f  h=%7.2f  cellFitting=%@  contentIdeal=%@  interactive=%@",
                row, rect.minY, rect.height, fitting, ideal,
                cell.map { $0.isContentInteractive ? "yes" : "no" } ?? "—"
            ))
        }
    }

    private func check(_ condition: Bool, _ description: String) {
        if condition {
            print("  ok   \(description)")
        } else {
            fail(description)
        }
    }

    private func fail(_ description: String) {
        failures.append(description)
        print("  FAIL \(description)")
    }

    private func finish() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        if failures.isEmpty {
            print("\nUIProbe: all checks passed")
            exit(0)
        }
        print("\nUIProbe: \(failures.count) failure(s)")
        for failure in failures {
            print("  - \(failure)")
        }
        exit(1)
    }
}
