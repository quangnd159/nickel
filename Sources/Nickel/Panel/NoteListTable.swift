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

    /// True while the coordinator is itself changing the table's selection or
    /// its rows. `tableViewSelectionDidChange` fires for those too, and writing
    /// them back would (among other things) drop selected notes that a search
    /// filter has merely hidden — which is deliberately preserved.
    private var isSyncingSelection = false

    /// The last reveal request acted on, so a re-render doesn't re-scroll.
    private var lastRevealToken: UUID?

    /// Everything a row's height can depend on. Row heights are only re-asked
    /// for when one of these changes — otherwise every unrelated re-render
    /// (typing in the composer, say) would force an Auto Layout pass over
    /// every row.
    private struct HeightInputs: Equatable {
        var notes: [Note]
        var editingID: UUID?
        var editingText: String
        var expandedIDs: Set<UUID>

        /// Expanding a row or opening an edit is a motion the user should be
        /// able to follow, so those animate; a store update or ordinary typing
        /// lands instantly — matching which of these the old SwiftUI list ran
        /// inside `withAnimation`.
        func animatesChange(from previous: HeightInputs) -> Bool {
            editingID != previous.editingID || expandedIDs != previous.expandedIDs
        }
    }

    private var lastHeightInputs: HeightInputs?

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
        table.usesAutomaticRowHeights = true
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

        // Row *content* updates itself: each cell hosts a SwiftUI view reading
        // the note straight out of the store, so a done toggle or a text edit
        // re-renders without the table being told. Only the row's height has
        // to be re-asked for.
        refreshRowHeights(rowsChanged: !steps.isEmpty)
        syncSelectionToTable()
        isSyncingSelection = false

        applyPendingReveal()
        claimFocusIfNothingHasIt()
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

    /// Re-asks Auto Layout for every row's height, when anything a height can
    /// depend on has changed. `usesAutomaticRowHeights` caches what it
    /// measured, so SwiftUI content that grows (a row expanded, an editor
    /// opened, a note's text changed) needs this to be picked up.
    private func refreshRowHeights(rowsChanged: Bool) {
        let inputs = HeightInputs(
            notes: store.notes,
            editingID: selection.editingID,
            editingText: selection.editingText,
            expandedIDs: selection.expandedIDs
        )
        defer { lastHeightInputs = inputs }
        guard let previous = lastHeightInputs else { return }
        guard rowsChanged || inputs != previous, !rows.isEmpty else { return }

        let all = IndexSet(integersIn: 0..<rows.count)
        guard inputs.animatesChange(from: previous) else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: all)
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tableView.animator().noteHeightOfRows(withIndexesChanged: all)
        }
    }

    /// The panel was resized: every row rewraps its text, so every cached
    /// height is stale.
    func invalidateAllRowHeights() {
        guard !rows.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
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
        cell.setContent(content(for: rows[row], at: row), interactive: isInteractive(rows[row]))
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
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
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

    func setContent(_ content: some View, interactive: Bool) {
        host.isInteractive = interactive
        host.rootView = AnyView(
            content.onPreferenceChange(NoteAttachmentFramesKey.self) { [weak self] frames in
                self?.attachmentFrames = frames
            }
        )
    }
}

/// A hosting view that is invisible to the mouse unless its content actually
/// needs clicks (a header's rename field, a note mid-inline-edit). Without
/// this the SwiftUI content would swallow every click and the table would
/// never see one, so none of its native selection behavior would run.
final class RowHostingView<Content: View>: NSHostingView<Content> {
    var isInteractive = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }
}
