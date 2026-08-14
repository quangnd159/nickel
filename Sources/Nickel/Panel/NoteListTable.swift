import AppKit
import SwiftUI

/// Which list the table is showing. The two differ only in row spacing, what
/// a row's content is, and whether the checkbox column is live — everything
/// else (selection, keyboard navigation, context menus) is shared.
enum NoteListMode {
    case notes
    case logbook

    /// Gap between rows. The Logbook's is a touch wider: its rows are flat
    /// (no card fill), so adjacent notes need the extra gap to not read as
    /// touching.
    var rowSpacing: CGFloat {
        switch self {
        case .notes: return 10
        case .logbook: return 14
        }
    }
}

/// The note list: a view-based `NSTableView` in a scroll view, with each row's
/// content hosted as SwiftUI.
///
/// The table owns interaction — click, ⇧-click, ⌘-click, arrows, ⇧-arrows,
/// ⌘A, right-click's `clickedRow` — and `SelectionModel.selectedIDs` stays the
/// app-facing source of truth, bridged both ways by the coordinator.
struct NoteListTable: NSViewRepresentable {
    let mode: NoteListMode

    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions

    func makeCoordinator() -> NoteListCoordinator {
        NoteListCoordinator(mode: mode)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(store: store, selection: selection, actions: actions)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: NoteListCoordinator) {
        coordinator.tearDown()
    }
}

// MARK: - Coordinator

/// Data source, delegate, and the two-way bridge between the table's native
/// selection and `SelectionModel`.
final class NoteListCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let mode: NoteListMode

    private(set) var rows: [NoteListRow] = []

    private var store: NoteStore!
    private var selection: SelectionModel!
    private var actions: PanelActions!

    private var scrollView: NSScrollView!
    private var tableView: NoteListTableView!

    /// Measures rows that have no cell yet — see `offscreenMeasuredHeight`.
    private lazy var measuringHost: RowHostingView<AnyView> = {
        let host = RowHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = [.intrinsicContentSize]
        return host
    }()

    /// True while the coordinator is itself changing the table's selection or
    /// its rows. `tableViewSelectionDidChange` fires for those too, and writing
    /// them back would (among other things) drop selected notes that a search
    /// filter has merely hidden — which is deliberately preserved.
    private var isSyncingSelection = false

    /// The last reveal request acted on, so a re-render doesn't re-scroll.
    private var lastRevealToken: UUID?

    /// Cells that have reported a new ideal height, batched until the end of
    /// the runloop turn so one settling pass costs one retile. Held as cells
    /// rather than row indices because a row can be inserted or removed before
    /// the batch is flushed, which would shift the indices out from under it.
    private let pendingHeightCells = NSHashTable<NoteListCellView>.weakObjects()
    private var pendingAllRowHeights = false
    private var isHeightFlushScheduled = false

    /// Expanding a row and opening/closing an inline edit are motions the user
    /// should be able to follow, so those height changes animate; ordinary
    /// typing and store updates land instantly — matching which of these the
    /// old SwiftUI list ran inside `withAnimation`. Set when the state changes
    /// and consumed by the flush the resulting relayout triggers.
    private var animatesPendingHeightChange = false
    private var lastEditingID: UUID?
    private var lastExpandedIDs: Set<UUID> = []

    init(mode: NoteListMode) {
        self.mode = mode
    }

    // MARK: Setup

    func makeScrollView() -> NSScrollView {
        let table = NoteListTableView()
        table.mode = mode
        table.coordinator = self
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .fullWidth
        // Heights come from `tableView(_:heightOfRow:)`, not
        // `usesAutomaticRowHeights` — see `height(ofRow:)`.
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: mode.rowSpacing)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnSelection = false
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        // Type-ahead would swallow Space, which the panel uses for "toggle
        // done"; there's nothing to type-select in a list of free text anyway.
        table.allowsTypeSelect = false
        // Group rows (section and day headers) scroll with the list, exactly
        // as the old inline SwiftUI headers did.
        table.floatsGroupRows = false
        table.selectionHighlightStyle = .regular
        table.gridStyleMask = []
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.doubleAction = #selector(NoteListTableView.handleDoubleClick)
        table.target = table

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let clipView = NoteListClipView()
        clipView.drawsBackground = false
        clipView.onBackgroundClick = { [weak self] in self?.handleBackgroundClick() }

        let scrollView = NSScrollView()
        scrollView.contentView = clipView
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false

        self.scrollView = scrollView
        self.tableView = table
        return scrollView
    }

    func tearDown() {
        tableView?.coordinator = nil
        tableView?.dataSource = nil
        tableView?.delegate = nil
    }

    // MARK: State push

    func update(store: NoteStore, selection: SelectionModel, actions: PanelActions) {
        self.store = store
        self.selection = selection
        self.actions = actions

        let newRows = NoteListRows.rows(store: store, selection: selection)
        let steps = NoteListDiff.steps(from: rows, to: newRows)

        isSyncingSelection = true
        if !steps.isEmpty {
            rows = newRows
            tableView.beginUpdates()
            if !steps.removals.isEmpty {
                tableView.removeRows(at: steps.removals, withAnimation: [.effectFade])
            }
            if !steps.insertions.isEmpty {
                tableView.insertRows(at: steps.insertions, withAnimation: [.effectFade])
            }
            tableView.endUpdates()
        }

        // A row's *text* updates itself: each cell hosts a SwiftUI view
        // reading the note straight out of the store, so a done toggle or an
        // edit re-renders without the table being told. What doesn't follow
        // from the store is everything the cell derives from the row model —
        // refreshed here — and the row's height, which the cell reports back
        // once its content has actually settled at its new size.
        noteHeightAnimationIntent()
        invalidateChangedRowHeights()
        refreshExistingCells()
        syncSelectionToTable()
        isSyncingSelection = false

        applyPendingReveal()
        claimFocusIfNothingHasIt()
    }

    /// Re-derives what a cell can't work out for itself. Every row that has a
    /// cell at all is covered — not just the ones on screen, since the table
    /// keeps cells a little past the viewport and won't rebuild those when
    /// they scroll back in. Rows with no cell yet are built current.
    private func refreshExistingCells() {
        for row in rows.indices {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteListCellView else {
                continue
            }
            cell.configure(
                content: content(for: rows[row], at: row),
                row: rows[row],
                index: row,
                interactive: isInteractive(rows[row])
            )
        }
    }

    private func noteHeightAnimationIntent() {
        if selection.editingID != lastEditingID || selection.expandedIDs != lastExpandedIDs {
            animatesPendingHeightChange = true
        }
        lastEditingID = selection.editingID
        lastExpandedIDs = selection.expandedIDs
    }

    /// The list is the panel's resting focus: with it first responder, the
    /// arrows, ⇧-arrows and ⌘A are the table's own. `FloatingPanel` hands
    /// focus here whenever something gives up text focus, but on the very
    /// first show the table may not exist yet when it tries — so the table
    /// claims it as soon as it does, and only when nothing else holds it.
    private func claimFocusIfNothingHasIt() {
        guard let window = tableView.window, window.firstResponder === window else { return }
        window.makeFirstResponder(tableView)
    }

    // MARK: Row heights

    /// Every row's height, keyed by the row itself. `NSTableView` asks for
    /// heights while it tiles — including for rows that have no cell yet — so
    /// this has to be a plain lookup that never lays anything out.
    ///
    /// `usesAutomaticRowHeights` was the obvious fit and doesn't work here:
    /// with SwiftUI-hosted cells it settles on the height it first measured
    /// and `noteHeightOfRows` doesn't move it (verified with `UIProbe` — every
    /// row stayed at one line's height while the cells' own fitting sizes were
    /// correct). `tableView(_:heightOfRow:)` has the documented counterpart:
    /// "If the delegate implements `tableView(_:heightOfRow:)` this method
    /// immediately retiles the table view using the row heights the delegate
    /// provides."
    private var rowHeights: [NoteListRow: CGFloat] = [:]

    /// Rows whose cached height is known to be out of date.
    private var staleHeightRows: Set<NoteListRow> = []

    /// Last seen note values, for spotting the ones that changed.
    private var lastNotesByID: [UUID: Note] = [:]

    /// Used before the table has a width to measure against; replaced as soon
    /// as a real measurement is possible.
    private static let provisionalRowHeight: CGFloat = 45

    /// A pure lookup. `NSTableView` asks for heights from inside its own
    /// layout pass, so measuring here — which lays SwiftUI content out —
    /// re-enters Auto Layout and trips its "still needs constraint update"
    /// assertion. Rows with no height yet get a provisional one and are
    /// measured on the next runloop turn instead.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return Self.provisionalRowHeight }
        guard let cached = rowHeights[rows[row]] else {
            scheduleHeightFlush()
            return Self.provisionalRowHeight
        }
        return cached
    }

    /// Measures every row that has no height yet or whose note changed while
    /// it had no cell to report for itself. Runs from the deferred flush,
    /// never inside a layout pass. Returns the rows whose height moved.
    private func measureOutstandingRowHeights() -> IndexSet {
        let width = tableView.bounds.width
        guard width > 0 else { return IndexSet() }
        var changed = IndexSet()
        var usedMeasuringHost = false

        for (index, item) in rows.enumerated() {
            guard rowHeights[item] == nil || staleHeightRows.contains(item) else { continue }

            let measured: CGFloat
            if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? NoteListCellView,
               cell.contentIdealHeight > 0 {
                // A row on screen already knows its own height.
                measured = cell.contentIdealHeight
            } else {
                measuringHost.rootView = AnyView(
                    content(for: item, at: index).frame(width: width, alignment: .leading)
                )
                measuringHost.setFrameSize(NSSize(width: width, height: 0))
                measuringHost.layoutSubtreeIfNeeded()
                measured = max(measuringHost.idealHeight, 1)
                usedMeasuringHost = true
            }

            if rowHeights[item] != measured { changed.insert(index) }
            rowHeights[item] = measured
        }
        staleHeightRows.removeAll()

        // Leaves nothing hosted: the measuring view builds a real copy of a
        // row's content, and for the row being edited that would include a
        // second editor. It's never in a window — `InlineNoteEditorField`
        // claims first responder through `view.window` — so it can't steal
        // focus, but there's no reason to keep it alive either.
        if usedMeasuringHost {
            measuringHost.rootView = AnyView(EmptyView())
        }
        return changed
    }

    /// A note's text can change while its row is scrolled out of sight, where
    /// there's no cell to notice. Marking it re-measures it on the next flush,
    /// keeping the old height until the new one is known rather than flashing
    /// through a placeholder. Also drops heights for rows that are gone.
    private func invalidateChangedRowHeights() {
        var current: [UUID: Note] = [:]
        current.reserveCapacity(store.notes.count)
        for note in store.notes {
            current[note.id] = note
            if lastNotesByID[note.id] != note {
                staleHeightRows.insert(.note(note.id))
            }
        }
        lastNotesByID = current

        let live = Set(rows)
        rowHeights = rowHeights.filter { live.contains($0.key) }
        if !staleHeightRows.isEmpty { scheduleHeightFlush() }
    }

    /// A cell's SwiftUI content has settled at a new height — the row grew
    /// into an inline editor, a note was expanded, its text changed. The
    /// content changes on SwiftUI's own render tick, after the state change
    /// that prompted it reached the table, so this is the moment the row's
    /// height is known.
    func rowHeight(_ height: CGFloat, didSettleIn cell: NoteListCellView) {
        let row = tableView.row(for: cell)
        guard rows.indices.contains(row), height > 0 else { return }
        guard rowHeights[rows[row]] != height else { return }
        rowHeights[rows[row]] = height
        pendingHeightCells.add(cell)
        scheduleHeightFlush()
    }

    /// The panel was resized: every row rewraps its text, so every height is
    /// stale.
    func invalidateAllRowHeights() {
        guard !rows.isEmpty else { return }
        rowHeights.removeAll()
        pendingAllRowHeights = true
        scheduleHeightFlush()
    }

    private func scheduleHeightFlush() {
        guard !isHeightFlushScheduled else { return }
        isHeightFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingRowHeights()
        }
    }

    private func flushPendingRowHeights() {
        isHeightFlushScheduled = false
        var indexes = measureOutstandingRowHeights()
        if pendingAllRowHeights, !rows.isEmpty {
            indexes.insert(integersIn: 0..<rows.count)
        }
        for cell in pendingHeightCells.allObjects {
            let row = tableView.row(for: cell)
            if rows.indices.contains(row) { indexes.insert(row) }
        }
        pendingAllRowHeights = false
        pendingHeightCells.removeAllObjects()

        let animates = animatesPendingHeightChange
        animatesPendingHeightChange = false
        guard !indexes.isEmpty else { return }

        guard animates else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: indexes)
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tableView.animator().noteHeightOfRows(withIndexesChanged: indexes)
        }
    }

    private func applyPendingReveal() {
        guard let request = selection.revealRequest, request.token != lastRevealToken else { return }
        lastRevealToken = request.token
        guard let row = rows.firstIndex(of: .note(request.id)) else { return }
        tableView.scrollRowToVisible(row)
    }

    // MARK: Selection bridge

    /// `SelectionModel` → table. Only the selected notes that are currently
    /// visible get rows; ones hidden by a search filter stay selected in the
    /// model and come back when the filter clears.
    private func syncSelectionToTable() {
        var indexes = IndexSet()
        for (index, row) in rows.enumerated() {
            if let id = row.noteID, selection.selectedIDs.contains(id) {
                indexes.insert(index)
            }
        }
        guard indexes != tableView.selectedRowIndexes else { return }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    /// Table → `SelectionModel`, for user-driven selection only.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, selection != nil else { return }
        let ids = tableView.selectedRowIndexes.compactMap { rows[$0].noteID }
        selection.selectedIDs = Set(ids)
    }

    /// Selects every note row — ⌘A. Headers are skipped, which
    /// `NSTableView.selectAll(_:)` on its own wouldn't do.
    func selectAllNoteRows() {
        var indexes = IndexSet()
        for (index, row) in rows.enumerated() where row.isSelectable {
            indexes.insert(index)
        }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    // MARK: Clicks

    /// Click on empty space below the rows: give up text focus (which commits
    /// an in-progress header rename, Finder-style), commit any in-progress
    /// note edit, and clear the selection.
    func handleBackgroundClick() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        actions?.commitActiveEditIfAny()
        selection?.clear()
    }

    /// A single click landing on `row`, before the table applies its own
    /// selection change. Returns `true` if the click was consumed (a checkbox
    /// hit, which stays selection-inert — a pure work-tracking control, the
    /// way Copper/Reminders/Things treat it).
    func handleClick(onRow row: Int, at pointInRow: NSPoint, clickCount: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        guard let id = rows[row].noteID else { return false }

        if mode == .notes, pointInRow.x < NoteRowMetrics.checkboxColumnWidth {
            // Only the first click of a double-click toggles: the second
            // would otherwise undo it, and a double-click on the checkbox has
            // never meant anything else.
            if clickCount == 1 { store.toggleDone(ids: [id]) }
            return true
        }

        // Clicking another row while this one is mid-edit tears its editor
        // down, and that commit-on-focus-loss can lose a race against the
        // selection change landing in the same tick. Committing here first
        // guarantees the edited text is saved.
        if selection.editingID != nil, selection.editingID != id {
            actions.commitActiveEditIfAny()
        }
        return false
    }

    /// Double-click: open a double-clicked attachment, otherwise begin an
    /// inline edit. Modifier-held double-clicks are range/toggle selection
    /// gestures, not edits.
    func handleDoubleClick(onRow row: Int, at pointInRow: NSPoint) {
        guard mode == .notes, rows.indices.contains(row), let id = rows[row].noteID else { return }
        guard pointInRow.x >= NoteRowMetrics.checkboxColumnWidth else { return }

        actions.commitActiveEditIfAny()

        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteListCellView,
           let hitID = cell.attachmentFrames.first(where: { $0.frame.contains(pointInRow) })?.id,
           let note = store.notes.first(where: { $0.id == id }),
           let attachment = note.attachments.first(where: { $0.id == hitID }) {
            NSWorkspace.shared.open(store.url(for: attachment, in: note))
            return
        }

        let flags = NSEvent.modifierFlags
        guard !flags.contains(.command), !flags.contains(.shift) else { return }
        guard let note = store.notes.first(where: { $0.id == id }) else { return }
        selection.selectSingle(id)
        selection.beginEditing(id: id, text: note.text)
    }

    /// Right-click, ahead of the menu opening. Matches AppKit's contextual
    /// menu convention: a right-click on a row that's already part of the
    /// selection acts on the whole selection, otherwise it selects just that
    /// row first.
    func handleRightClick(onRow row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        guard let id = rows[row].noteID else { return nil }
        actions.selectOnRightClick(id)
        return NoteContextMenu.menu(mode: mode, store: store, selection: selection, actions: actions)
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        !rows[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NoteListRowView()
        // The selection outline is drawn by the row's own SwiftUI content (the
        // exact same `strokeBorder` the old list used), so the row view must
        // draw neither the default fill nor the group-row background.
        view.isGroupRowStyle = false
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NoteListCellView()
        cell.onIdealHeightChange = { [weak self, weak cell] height in
            guard let self, let cell else { return }
            self.rowHeight(height, didSettleIn: cell)
        }
        cell.configure(
            content: content(for: rows[row], at: row),
            row: rows[row],
            index: row,
            interactive: isInteractive(rows[row])
        )
        return cell
    }

    /// Rows whose content takes clicks itself. Everything else is hit-test
    /// transparent so the table sees the click and applies its own native
    /// selection — the one thing a SwiftUI-hosted row would otherwise swallow.
    private func isInteractive(_ row: NoteListRow) -> Bool {
        switch row {
        case .sectionHeader:
            // Double-click to rename, its own context menu, and the inline
            // rename field all live in the header's SwiftUI content.
            return true
        case .note(let id):
            return selection.editingID == id
        case .dayHeader, .logbookFooter:
            return false
        }
    }

    @ViewBuilder
    private func content(for row: NoteListRow, at index: Int) -> some View {
        switch row {
        case .note(let id):
            if mode == .logbook {
                LogbookRowContent(noteID: id)
                    .environmentObject(store)
                    .environmentObject(selection)
                    .environmentObject(actions)
            } else {
                NoteRowContent(noteID: id)
                    .environmentObject(store)
                    .environmentObject(selection)
                    .environmentObject(actions)
            }
        case .sectionHeader(let name):
            SectionHeader(name: name)
                // The gap above a section header is wider than the gap between
                // notes, exactly as the old list's `.padding(.top, 12)` on top
                // of the `VStack`'s spacing made it.
                .padding(.top, 12)
                .environmentObject(store)
                .environmentObject(selection)
                .environmentObject(actions)
        case .dayHeader(let day):
            LogbookDayHeader(day: day)
                .padding(.top, index == 0 ? 0 : 12)
        case .logbookFooter:
            LogbookFooter()
                .padding(.top, 8)
        }
    }
}

// MARK: - Table view

/// The note list's table. Everything overridden here is a click or key that
/// the panel owns rather than the table: the checkbox column, empty-space
/// clicks, right-click pre-selection, ⌘A over note rows only, and the panel's
/// own shortcut keys, which are passed up the responder chain to
/// `FloatingPanel.keyDown` exactly as they were before the table existed.
final class NoteListTableView: NSTableView {
    weak var coordinator: NoteListCoordinator?
    var mode: NoteListMode = .notes

    override var acceptsFirstResponder: Bool { true }

    /// A narrower list rewraps every row's text, so every height the table
    /// cached is stale.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { coordinator?.invalidateAllRowHeights() }
    }

    private func pointInRow(_ event: NSEvent, row: Int) -> NSPoint {
        let pointInTable = convert(event.locationInWindow, from: nil)
        let rowRect = rect(ofRow: row)
        return NSPoint(x: pointInTable.x - rowRect.minX, y: pointInTable.y - rowRect.minY)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)

        guard row >= 0 else {
            coordinator?.handleBackgroundClick()
            return
        }

        let consumed = coordinator?.handleClick(
            onRow: row,
            at: pointInRow(event, row: row),
            clickCount: event.clickCount
        )
        if consumed == true { return }
        super.mouseDown(with: event)
    }

    @objc func handleDoubleClick() {
        let row = clickedRow
        guard row >= 0, let event = NSApp.currentEvent else { return }
        coordinator?.handleDoubleClick(onRow: row, at: pointInRow(event, row: row))
    }

    /// `super` sets `clickedRow`/`clickedColumn` and draws the contextual
    /// menu's row highlight; the coordinator adjusts the selection first and
    /// hands back the menu built for it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        menu = coordinator?.handleRightClick(onRow: row)
        return super.menu(for: event)
    }

    /// ⌘A. `NSTableView`'s own `selectAll(_:)` would include the section and
    /// day header rows.
    override func selectAll(_ sender: Any?) {
        coordinator?.selectAllNoteRows()
    }

    /// The arrows are the table's own navigation (it moves the selection and
    /// keeps the lead row visible); every other key the panel has a shortcut
    /// for goes up the responder chain to `FloatingPanel.keyDown`, which is
    /// where Space, Return, ⌫, Esc and the ⌘ shortcuts were always handled.
    /// Anything the panel doesn't claim (Page Up/Down, Home/End) stays with
    /// the table.
    override func keyDown(with event: NSEvent) {
        if let command = PanelShortcuts.command(for: event), command != .moveDown, command != .moveUp {
            nextResponder?.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }
}

/// Suppresses the default selection fill and group-row background: a row's
/// selected look is the 2pt outline its SwiftUI content draws.
final class NoteListRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    /// A selected row normally reports `.emphasized` here, which tells the
    /// cell's content to draw for a filled accent highlight — SwiftUI hosted
    /// in the cell responds by flipping `.primary` text to white, invisible
    /// on the card's white fill. This row never draws that highlight, so its
    /// content must always draw as normal.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Catches clicks that land in the scroll view but below the last row — the
/// table view itself only covers the height its rows occupy.
final class NoteListClipView: NSClipView {
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }
}

// MARK: - Cell

/// A row's cell: a SwiftUI view in a hosting view pinned to the cell's edges,
/// so `usesAutomaticRowHeights` gets the row height straight from the
/// content's own layout.
final class NoteListCellView: NSTableCellView {
    private let host = RowHostingView(rootView: AnyView(EmptyView()))

    /// Live frames of the row's attachment thumbnails/cards, in the cell's
    /// coordinate space, so a double-click can be told apart from one landing
    /// elsewhere on the card.
    private(set) var attachmentFrames: [NoteAttachmentFrame] = []

    /// What this cell was last built for. A cell outlives any one update — the
    /// table keeps it as rows come and go around it — so everything derived
    /// from the row model has to be re-derived, not captured once at creation.
    private var configuredRow: NoteListRow?
    private var configuredIndex: Int?

    /// The content as the coordinator built it, before the width is pinned on
    /// (see `applyContent`), so a resize can re-pin without rebuilding it.
    private var baseContent: AnyView = AnyView(EmptyView())
    private var contentWidth: CGFloat = 0
    private var isContentApplyScheduled = false

    var onIdealHeightChange: ((CGFloat) -> Void)? {
        get { host.onIdealHeightChange }
        set { host.onIdealHeightChange = newValue }
    }

    /// Whether this cell's content currently takes clicks. Read by `UIProbe`.
    var isContentInteractive: Bool { host.isInteractive }

    /// The height this cell's content wants at its current width. Read by
    /// `UIProbe`.
    var contentIdealHeight: CGFloat { host.idealHeight }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = [.intrinsicContentSize]
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Applied on every update, not just at creation. `interactive` in
    /// particular changes during a cell's life: the row being edited has to
    /// take clicks so the caret can be placed, and give them back up when the
    /// edit ends. Re-hosting the content is the expensive half, so that only
    /// happens when the row or its position actually changed.
    func configure(content: some View, row: NoteListRow, index: Int, interactive: Bool) {
        host.isInteractive = interactive
        guard configuredRow != row || configuredIndex != index else { return }
        configuredRow = row
        configuredIndex = index
        baseContent = AnyView(
            content.onPreferenceChange(NoteAttachmentFramesKey.self) { [weak self] frames in
                self?.attachmentFrames = frames
            }
        )
        applyContent()
    }

    /// Deferred, not applied in place: re-hosting the content invalidates
    /// SwiftUI's layout, and doing that from inside AppKit's own layout pass
    /// re-enters it.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 0, newSize.width != contentWidth else { return }
        contentWidth = newSize.width
        guard !isContentApplyScheduled else { return }
        isContentApplyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isContentApplyScheduled = false
            self.applyContent()
        }
    }

    /// Hosts the content at the cell's exact width.
    ///
    /// The width has to be pinned in SwiftUI, not just constrained in AppKit:
    /// `NSHostingView`'s `sizingOptions` reflect the content's *ideal* size,
    /// and a `Text`'s ideal size is its unwrapped single line. Hosting a
    /// wrapping note without a fixed width therefore reports one line's height
    /// no matter how long the note is — which is exactly what the table then
    /// used as the row height. Fixing the width makes the ideal height the
    /// wrapped height.
    private func applyContent() {
        guard contentWidth > 0 else {
            host.rootView = baseContent
            return
        }
        host.rootView = AnyView(baseContent.frame(width: contentWidth, alignment: .leading))
        host.contentDidChange()
    }
}

/// A hosting view that is invisible to the mouse unless its content actually
/// needs clicks (a header's rename field, a note mid-inline-edit). Without
/// this the SwiftUI content would swallow every click and the table would
/// never see one, so none of its native selection behavior would run.
///
/// It also reports when the hosted content's ideal height changes, which is
/// the only reliable moment to re-measure the row. The cell's content is its
/// own SwiftUI hierarchy observing the same state the table does, and it swaps
/// in (say) the inline editor on SwiftUI's render tick — after the table has
/// already been told about the state change. `sizingOptions` turns that new
/// ideal size into constraints via `updateConstraints()`/`layout()`, so those
/// are where the row's height is known to be stale.
final class RowHostingView<Content: View>: NSHostingView<Content> {
    var isInteractive = false

    /// Called on the next runloop turn — after SwiftUI has applied the change
    /// that prompted it — whenever the content's height moves.
    var onIdealHeightChange: ((CGFloat) -> Void)?

    private var lastIdealHeight: CGFloat?
    private var isHeightCheckScheduled = false

    /// The height the content wants right now.
    var idealHeight: CGFloat { intrinsicContentSize.height }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        scheduleIdealHeightCheck()
    }

    override func layout() {
        super.layout()
        scheduleIdealHeightCheck()
    }

    /// Wholly different content is being hosted, so the remembered height
    /// says nothing about it.
    func contentDidChange() {
        lastIdealHeight = nil
        scheduleIdealHeightCheck()
    }

    /// Deferred rather than measured in place: `layout()` and
    /// `invalidateIntrinsicContentSize()` both run mid-layout, where asking
    /// for a size would either re-enter or read the size being replaced.
    private func scheduleIdealHeightCheck() {
        guard !isHeightCheckScheduled else { return }
        isHeightCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isHeightCheckScheduled = false
            let height = self.idealHeight
            guard height > 0, height != self.lastIdealHeight else { return }
            self.lastIdealHeight = height
            self.onIdealHeightChange?(height)
        }
    }
}
