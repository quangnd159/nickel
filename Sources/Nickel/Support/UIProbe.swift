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

    /// Long enough that its inline editor is taller than the whole viewport,
    /// so the reveal has to pick which end of the row to show.
    private static let veryLongNoteText = Array(repeating: longNoteText, count: 3).joined(separator: "\n\n")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unbuffered, so the probe's own prints interleave truthfully with
        // NSLog-based debug output when both are captured to one file.
        setbuf(stdout, nil)
        // Deterministic geometry: a headless CI runner never ticks AppKit's
        // animated scrolls, so an animated reveal would leave the viewport
        // stranded mid-flight there. Reduced motion makes every reveal land
        // instantly; the one check that needs a real animation (edit-open
        // stationarity) clears this override for its own scope.
        Motion.probeOverrideReduced = true

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

        // Every row's cached height — what a reveal is computed from — has to
        // be the height its cell actually lays out at. A sweep rather than one
        // sample: the two only diverge for text that wraps differently at the
        // measured width than at the real one, so a single note can easily
        // agree by luck.
        checkCachedHeightsMatchCells(table: table)

        // A resize must keep the long row's height readable — not flash to
        // the placeholder — until the flush re-measures it at the new width.
        checkWidthInvalidation(table: table, panel: panel, row: longRow)

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

        checkDragMove(table: table, store: store, selection: selection)

        checkDelegateGuards(table: table)

        finish()
    }

    /// What a completed drop does to the list, short of the gesture itself:
    /// `acceptDrop` calls exactly this store mutation and sets exactly this
    /// selection, so everything downstream of the pointer is covered here.
    /// Dragging with a real mouse stays a manual check.
    private func checkDragMove(table: NoteListTableView, store: NoteStore, selection: SelectionModel) {
        selection.endEditing()
        store.setActiveSection(nil)
        settle()

        guard let moved = store.activeNotes.first(where: { $0.text.count > 200 }) else {
            fail("no long note to drag")
            return
        }

        // Expanded, so the row has a distinctive height that a naive rebuild
        // would lose.
        if !selection.expandedIDs.contains(moved.id) {
            selection.toggleExpanded(ids: [moved.id])
        }
        settle()
        guard let beforeRow = table.coordinator?.rows.firstIndex(of: .note(moved.id)) else {
            fail("the note to drag has no row")
            return
        }
        let heightBefore = table.rect(ofRow: beforeRow).height
        print("— before the drop —")
        print("  row \(beforeRow) height=\(heightBefore)")

        // Exactly what `acceptDrop` does for a drop in the gap below the
        // "Probe Section" header — the section is empty, so that gap resolves
        // to its end — plus keeping the dragged notes selected and re-seating
        // the rows as moves.
        store.move(ids: [moved.id], toSection: "Probe Section", before: nil)
        selection.selectedIDs = [moved.id]

        guard let coordinator = table.coordinator else {
            fail("the table has no coordinator")
            return
        }
        let expectedRows = NoteListRows.rows(store: store, selection: selection)
        coordinator.applyDropAsMoves(to: expectedRows)

        // Checked before settling, deliberately: the drop's own transaction has
        // to leave the table already agreeing with the store. Anything left for
        // the next update to notice would be a reorder the diff expresses as a
        // remove and an insert — the flash the move path exists to avoid.
        check(
            coordinator.rows == expectedRows,
            "the table's rows match the store immediately after the drop transaction"
        )
        check(
            table.numberOfRows == expectedRows.count,
            "the table's row count matches immediately after the drop transaction "
                + "(\(table.numberOfRows) vs \(expectedRows.count))"
        )

        settle()

        // And nothing was left over for the next update to animate.
        check(
            NoteListDiff.steps(from: coordinator.rows, to: NoteListRows.rows(store: store, selection: selection)).isEmpty,
            "the update after a drop has nothing left to diff"
        )

        guard let rows = table.coordinator?.rows,
              let afterRow = rows.firstIndex(of: .note(moved.id)) else {
            fail("the dragged note vanished from the list")
            return
        }
        let heightAfter = table.rect(ofRow: afterRow).height
        print("— after the drop —")
        print("  row \(afterRow) height=\(heightAfter)")

        check(
            heightAfter == heightBefore,
            "a dropped row keeps the height it was measured at "
                + "(\(heightBefore) before, \(heightAfter) after)"
        )
        check(
            rows.firstIndex(of: .sectionHeader("Probe Section")).map { $0 < afterRow } == true,
            "the dropped note should land under its new section's header"
        )
        check(
            selection.selectedIDs == [moved.id],
            "the dragged notes stay selected after the drop"
        )
        check(
            store.notes.first(where: { $0.id == moved.id })?.listName == "Probe Section",
            "the dropped note should belong to the section it was dropped into"
        )

        // And the row is still a live, correctly sized cell at its new home.
        table.scrollRowToVisible(afterRow)
        settle()
        guard let cell = table.view(atColumn: 0, row: afterRow, makeIfNecessary: false) as? NoteListCellView else {
            fail("the dropped note's row has no cell")
            return
        }
        check(
            abs((heightAfter - table.intercellSpacing.height) - cell.contentIdealHeight) < 0.5,
            "the dropped row's height still matches its cell's layout "
                + "(\(heightAfter - table.intercellSpacing.height) vs \(cell.contentIdealHeight))"
        )
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
        // The collapse hold (full content kept on screen while the card
        // shuts) must be released once the height flush completes — a leaked
        // hold would leave the row clipping its full text forever.
        check(
            selection.collapseHold.isEmpty,
            "the collapse hold should be released after the collapse settles"
        )

        // Beginning an edit on the bottom note reveals the row like ⌘E does;
        // this editor fits the viewport, so its end (and the caret) lands on
        // screen.
        selection.selectSingle(bottomNote.id)
        selection.beginEditing(id: bottomNote.id, text: bottomNote.text)
        settle()
        let editingVisible = clipView.documentVisibleRect
        let editingRow = table.rect(ofRow: bottomRow)
        print("— bottom row, editing —")
        print("  visible=\(editingVisible)  row=\(editingRow)")
        if let cell = table.view(atColumn: 0, row: bottomRow, makeIfNecessary: false) {
            let card = cell.convert(cell.bounds, to: table)
            print("  card=\(card)  cardBottom−visibleBottom=\(card.maxY - editingVisible.maxY)")
        }
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

        // The core of the open animation's feel: the row grows and reveals
        // the text — the text itself must be stationary the whole time. The
        // cell is a clipping window over content that is never re-laid-out
        // mid-animation (no bottom constraint on the host), so the editor's
        // position in table coordinates must not drift by a point across the
        // animation's run. (Table coordinates are content-relative, so the
        // reveal scroll doesn't pollute the samples.)
        // Animations back on for the stationarity check below: it samples a
        // real animated open. Its assertions are in content coordinates, so
        // they hold whether or not the runner actually ticks the animation.
        Motion.probeOverrideReduced = false
        selection.selectSingle(bottomNote.id)
        settle()
        // The selection ring lives on the cell's layer (not in the SwiftUI
        // content) so it rides the row's animated bounds instead of being
        // clipped mid-animation. Selected: 2pt border; deselected: none.
        if let selectedCell = table.view(atColumn: 0, row: bottomRow, makeIfNecessary: false) {
            check(
                selectedCell.layer?.borderWidth == 2,
                "a selected row's cell should carry the 2pt selection ring on its layer "
                    + "(borderWidth \(selectedCell.layer?.borderWidth ?? -1))"
            )
        } else {
            fail("the selected row has no cell to check the ring on")
        }
        selection.beginEditing(id: bottomNote.id, text: bottomNote.text)
        var textYs: [CGFloat] = []
        let deadline = Date().addingTimeInterval(0.35)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if let cell = table.view(atColumn: 0, row: bottomRow, makeIfNecessary: false),
               let textView = firstTextView(in: cell) {
                textYs.append(textView.convert(NSPoint.zero, to: table).y)
            }
        }
        settle()
        print("— edit-open stationarity —")
        print("  samples=\(textYs.count)  yRange=\(String(describing: textYs.min()))…\(String(describing: textYs.max()))")
        if let minY = textYs.min(), let maxY = textYs.max() {
            check(
                maxY - minY < 0.5,
                "the editor's text must not move while the open animation runs "
                    + "(drifted \(maxY - minY) points)"
            )
        } else {
            fail("no editor samples were captured during the open animation")
        }
        selection.endEditing()
        settle()
        Motion.probeOverrideReduced = true

        checkTallEditReveal(table: table, store: store, selection: selection, clipView: clipView)
    }

    /// The case the shorter notes above never reach: an editor taller than the
    /// viewport. The caret is on the last line, and the card has to be visibly
    /// closed under it — bottom padding, stroke and the full corner radius —
    /// not cut off at the viewport's edge.
    private func checkTallEditReveal(
        table: NoteListTableView,
        store: NoteStore,
        selection: SelectionModel,
        clipView: NSClipView
    ) {
        store.add(text: Self.veryLongNoteText, sourceApp: nil)
        let tallNoteID = store.activeNotes.last?.id
        // Rows below it, so the reveal is computed on its own merits instead
        // of being pinned by the clamp at the end of the content — which is
        // what hid the two reveal paths disagreeing.
        for index in 0..<6 {
            store.add(text: "Tail note \(index)", sourceApp: nil)
        }
        settle()

        guard let tallNoteID,
              let tallNote = store.activeNotes.first(where: { $0.id == tallNoteID }),
              let tallRow = table.coordinator?.rows.firstIndex(of: .note(tallNote.id)) else {
            fail("could not find the very long note's row")
            return
        }

        selection.selectSingle(tallNote.id)
        selection.beginEditing(id: tallNote.id, text: tallNote.text)
        settle()

        let visible = clipView.documentVisibleRect
        let rowRect = table.rect(ofRow: tallRow)
        print("— editor taller than the viewport —")
        print("  visible=\(visible)  row=\(rowRect)")
        guard let cell = table.view(atColumn: 0, row: tallRow, makeIfNecessary: false) else {
            fail("the tall editing row has no cell")
            return
        }
        let card = cell.convert(cell.bounds, to: table)
        print("  card=\(card)  cardBottom−visibleBottom=\(card.maxY - visible.maxY)")
        if let cell = cell as? NoteListCellView {
            print("  tableWidth=\(table.bounds.width)  cellWidth=\(cell.bounds.width)")
            print("  frameOfCell=\(table.frameOfCell(atColumn: 0, row: tallRow).width)  column=\(table.tableColumns[0].width)")
            print("  cachedRowHeight=\(rowRect.height)  liveCellIdeal=\(cell.contentIdealHeight)")
            // The invariant that keeps the begin-edit reveal and the caret
            // follow agreeing: the height the reveal was computed from is the
            // height the row actually ended up with.
            check(
                abs((rowRect.height - table.intercellSpacing.height) - cell.contentIdealHeight) < 0.5,
                "the row height the reveal used (\(rowRect.height - table.intercellSpacing.height)) "
                    + "must match what the cell actually lays out at (\(cell.contentIdealHeight))"
            )
        }

        check(
            rowRect.height > visible.height,
            "the probe's tall note should actually exceed the viewport "
                + "(row \(rowRect.height), viewport \(visible.height))"
        )
        check(
            card.maxY <= visible.maxY + 0.5,
            "the card's bottom edge (\(card.maxY)) must be inside the viewport (ends \(visible.maxY))"
        )
        // The corner radius is the deepest part of the card's bottom edge, so
        // seeing the whole corner is what "visibly closed" means.
        check(
            card.maxY - NoteRowMetrics.cornerRadius >= visible.minY,
            "the card's bottom corners should be fully on screen "
                + "(corner starts \(card.maxY - NoteRowMetrics.cornerRadius), viewport starts \(visible.minY))"
        )
        // Two-sided on purpose. Scrolling too far is as wrong as too short,
        // and both come from the same fault — a row revealed at a height it
        // doesn't have. Under-measure and the card lands below the viewport
        // (clipped); over-measure and the list overshoots past it.
        check(
            abs(rowRect.maxY - visible.maxY) < 0.5,
            "the reveal should seat the row's bottom exactly on the viewport's "
                + "(row ends \(rowRect.maxY), viewport ends \(visible.maxY))"
        )

        // Typing is the case that actually bites: `NSTextView` reveals the
        // caret itself on every insertion, and its idea of the caret is the
        // glyph, with none of the card around it.
        if let textView = firstTextView(in: cell) {
            let beforeTyping = clipView.bounds.origin.y
            textView.insertText("x", replacementRange: textView.selectedRange())
            settle()
            let typedVisible = clipView.documentVisibleRect
            let typedCard = cell.convert(cell.bounds, to: table)
            print("— after typing at the end —")
            print("  visible=\(typedVisible)  card=\(typedCard)")
            print("  cardBottom−visibleBottom=\(typedCard.maxY - typedVisible.maxY)")
            check(
                typedCard.maxY <= typedVisible.maxY + 0.5,
                "typing on the last line must keep the card's bottom edge visible "
                    + "(card ends \(typedCard.maxY), viewport ends \(typedVisible.maxY))"
            )
            // The point of the whole exercise: opening the edit has to land
            // exactly where the caret-follow reveal would, so the first
            // keystroke moves nothing at all.
            check(
                clipView.bounds.origin.y == beforeTyping,
                "the first keystroke must not scroll at all "
                    + "(was \(beforeTyping), now \(clipView.bounds.origin.y))"
            )

            #if DEBUG
            // Plan 036: a keystroke changes `editingText`, which is deliberately
            // absent from the update stamp, so it must never make it through to
            // the heavy tail of `update(...)` — only the cheap early-out.
            if let coordinator = table.coordinator {
                let before = coordinator.heavyUpdateRunCount
                for character in ["y", "z", "w"] {
                    textView.insertText(character, replacementRange: textView.selectedRange())
                    settle()
                }
                check(
                    coordinator.heavyUpdateRunCount == before,
                    "typing does not run the full list pipeline "
                        + "(heavyUpdateRunCount was \(before), now \(coordinator.heavyUpdateRunCount))"
                )
            } else {
                fail("the table has no coordinator to check heavyUpdateRunCount on")
            }
            #endif

            // A trailing newline is the case the inert measurement twin has
            // to special-case (`NSTextView` reserves a line for it; `Text`
            // doesn't). Type one, then force the row through the stale
            // measurement path — `invalidateAllRowHeights` marks every row
            // stale, and `measureOutstandingRowHeights` takes the stale
            // branch (the inert twin) even for a row with a live cell on
            // screen — and confirm the inert twin's height still matches
            // what the live editor cell lays out at.
            textView.insertText("\n", replacementRange: textView.selectedRange())
            table.coordinator?.invalidateAllRowHeights()
            settle()
            let newlineRowRect = table.rect(ofRow: tallRow)
            if let liveCell = table.view(atColumn: 0, row: tallRow, makeIfNecessary: false) as? NoteListCellView {
                print("— after typing a trailing newline (forced through the stale/inert-twin path) —")
                print("  cachedRowHeight=\(newlineRowRect.height)  liveCellIdeal=\(liveCell.contentIdealHeight)")
                check(
                    abs((newlineRowRect.height - table.intercellSpacing.height) - liveCell.contentIdealHeight) < 0.5,
                    "the inert twin's cached height after a trailing newline (\(newlineRowRect.height - table.intercellSpacing.height)) "
                        + "must match what the live editor cell actually lays out at (\(liveCell.contentIdealHeight))"
                )
            } else {
                fail("the tall editing row has no cell after typing a trailing newline")
            }
        } else {
            fail("no text view in the editing cell")
        }

        selection.endEditing()
        settle()

        // Closing the edit collapses the row back to its preview far above
        // where the caret reveal had scrolled to; the collapsed row must be
        // brought back on screen in the same motion, not left out of view.
        let closedVisible = clipView.documentVisibleRect
        let closedRow = table.rect(ofRow: tallRow)
        print("— after closing the tall edit —")
        print("  visible=\(closedVisible)  row=\(closedRow)")
        check(
            closedRow.intersects(closedVisible),
            "closing an edit must keep the collapsed row on screen "
                + "(row \(closedRow), viewport \(closedVisible))"
        )
    }

    /// Checks every row that has a cell: the height the table is using must be
    /// the height that cell lays out at. Scrolls the list through so every row
    /// gets a cell at some point.
    private func checkCachedHeightsMatchCells(table: NoteListTableView) {
        var mismatches: [String] = []
        var checked = 0
        let spacing = table.intercellSpacing.height

        for row in 0..<table.numberOfRows {
            table.scrollRowToVisible(row)
            settle(seconds: 0.15)
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteListCellView,
                  cell.contentIdealHeight > 0 else { continue }
            checked += 1
            let used = table.rect(ofRow: row).height - spacing
            if abs(used - cell.contentIdealHeight) >= 0.5 {
                mismatches.append("row \(row): using \(used), cell lays out at \(cell.contentIdealHeight)")
            }
        }

        print("— cached heights vs cells —")
        print("  checked \(checked) rows, \(mismatches.count) mismatched")
        for mismatch in mismatches.prefix(6) {
            print("    \(mismatch)")
        }
        check(
            mismatches.isEmpty,
            "every row's height must match its cell's layout (\(mismatches.count) of \(checked) wrong)"
        )
    }

    /// A resize marks every row's cached height stale rather than wiping the
    /// cache, so `heightOfRow` keeps answering with the pre-resize value
    /// until the deferred flush re-measures — never the 45pt placeholder a
    /// wipe would produce for a runloop turn. Checked immediately after the
    /// resize, before spinning the runloop, then again once it settles.
    private func checkWidthInvalidation(table: NoteListTableView, panel: FloatingPanel, row: Int) {
        guard let delegate = table.delegate else {
            fail("table has no delegate to probe (width invalidation)")
            return
        }
        let beforeHeight = delegate.tableView?(table, heightOfRow: row)

        let originalFrame = panel.frame
        var narrower = originalFrame
        narrower.size.width -= 40
        panel.setFrame(narrower, display: true)

        let duringHeight = delegate.tableView?(table, heightOfRow: row)
        print("— width invalidation —")
        print("  before=\(String(describing: beforeHeight))  immediately after resize=\(String(describing: duringHeight))")
        check(
            duringHeight == beforeHeight,
            "right after a resize, a row's height should still read its pre-resize value, "
                + "not the placeholder (before \(String(describing: beforeHeight)), "
                + "immediately after \(String(describing: duringHeight)))"
        )

        settle()
        table.scrollRowToVisible(row)
        settle(seconds: 0.15)

        guard let settledCell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteListCellView,
              settledCell.contentIdealHeight > 0 else {
            fail("no settled cell for the probed row after resizing")
            panel.setFrame(originalFrame, display: true)
            settle()
            return
        }
        let spacing = table.intercellSpacing.height
        let settledUsed = table.rect(ofRow: row).height - spacing
        print("  settled: used=\(settledUsed)  cellIdeal=\(settledCell.contentIdealHeight)")
        check(
            abs(settledUsed - settledCell.contentIdealHeight) < 0.5,
            "after settling post-resize, the row's height should match its cell's new layout "
                + "(\(settledUsed) vs \(settledCell.contentIdealHeight))"
        )

        // Leave the panel as the rest of the probe found it.
        panel.setFrame(originalFrame, display: true)
        settle()
    }

    /// The table asks its delegate about row indices outside the current
    /// model (`.gap` drop feedback, animated removals) — `heightOfRow`
    /// already guards for that; this checks the other callbacks answer
    /// out-of-range asks without trapping, and that a row rect and its cell
    /// frame agree on where the row starts.
    private func checkDelegateGuards(table: NoteListTableView) {
        guard let delegate = table.delegate else {
            fail("table has no delegate to probe")
            return
        }
        let rowCount = table.numberOfRows

        print("— delegate guards —")
        check(
            delegate.tableView?(table, isGroupRow: rowCount) == false,
            "isGroupRow(rowCount) should return false, not trap"
        )
        check(
            delegate.tableView?(table, isGroupRow: rowCount + 1) == false,
            "isGroupRow(rowCount + 1) should return false, not trap"
        )
        check(
            delegate.tableView?(table, shouldSelectRow: rowCount) == false,
            "shouldSelectRow(rowCount) should return false, not trap"
        )
        check(
            delegate.tableView?(table, shouldSelectRow: rowCount + 1) == false,
            "shouldSelectRow(rowCount + 1) should return false, not trap"
        )
        check(
            delegate.tableView?(table, viewFor: table.tableColumns[0], row: rowCount) == nil,
            "viewFor(rowCount) should return nil, not trap"
        )

        // Coordinate-space agreement: the probe originally measured a 6pt
        // x-origin delta between a row's rect and its cell's frame (the
        // `.fullWidth` style's inset), which is why `pointInRow` derives the
        // click point from `frameOfCell`, not `rect(ofRow:)`. Pin that the
        // delta is still the inset the fix compensates for — if the table
        // style ever changes it, this surfaces the drift.
        if rowCount > 0 {
            let rowRect = table.rect(ofRow: 0)
            let cellFrame = table.frameOfCell(atColumn: 0, row: 0)
            let delta = cellFrame.minX - rowRect.minX
            check(
                delta >= 0 && cellFrame.width <= rowRect.width,
                "cell frame sits inside its row rect (x-inset \(delta)); pointInRow uses the cell frame"
            )
        }
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
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
