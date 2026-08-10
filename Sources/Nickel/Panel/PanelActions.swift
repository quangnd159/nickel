import AppKit

/// Actions available on the panel's current selection: copy, mark done,
/// edit, merge, move to list, delete. Shared between the SwiftUI context
/// menu/overflow menu and the AppKit keyboard-shortcut handling in
/// `FloatingPanel` so both drive the exact same logic.
final class PanelActions: ObservableObject {
    let store: NoteStore
    let selection: SelectionModel

    init(store: NoteStore, selection: SelectionModel) {
        self.store = store
        self.selection = selection
    }

    /// The selected notes, in visible (not selection-insertion) order.
    private var selectedNotes: [Note] {
        notes(for: selection.visibleOrder.filter { selection.selectedIDs.contains($0) })
    }

    /// All currently-visible notes, in visible order.
    private var allVisibleNotes: [Note] {
        notes(for: selection.visibleOrder)
    }

    private func notes(for ids: [UUID]) -> [Note] {
        let byID = Dictionary(store.activeNotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    var allSelectedAreDone: Bool {
        let ids = selection.selectedIDs
        guard !ids.isEmpty else { return false }
        var sawAny = false
        for note in store.activeNotes where ids.contains(note.id) {
            if !note.isDone { return false }
            sawAny = true
        }
        return sawAny
    }

    var allSelectedAreExpanded: Bool {
        let ids = selection.selectedIDs
        return !ids.isEmpty && ids.isSubset(of: selection.expandedIDs)
    }

    // MARK: - Copy

    func copy() {
        let notes = selectedNotes
        guard let layout = PasteboardWriter.copy(notes: notes, store: store) else { return }
        SequentialPasteCoordinator.shared.handleCopy(notes: notes, layout: layout)
    }

    func copyAsList() {
        let notes = selectedNotes
        guard let layout = PasteboardWriter.copyAsList(notes: notes, store: store) else { return }
        SequentialPasteCoordinator.shared.handleCopy(notes: notes, layout: layout)
    }

    func copyAllAsList() {
        let notes = allVisibleNotes
        guard let layout = PasteboardWriter.copyAsList(notes: notes, store: store) else { return }
        SequentialPasteCoordinator.shared.handleCopy(notes: notes, layout: layout)
    }

    // MARK: - Done / edit / merge / delete

    /// Logbook rows are a read-only record: no done toggling, no editing, no
    /// merging or moving. Every action that changes a note's content or place
    /// checks this first; copying and selection stay available.
    private var isShowingLogbook: Bool { selection.isShowingLogbook }

    func toggleDone() {
        guard !isShowingLogbook, !selection.selectedIDs.isEmpty else { return }
        store.toggleDone(ids: selection.selectedIDs)
    }

    /// Expand/collapse toggle, driven by both the context menu item and ⌘E
    /// (see `FloatingPanel.handle(_:actions:)` — a context menu's own
    /// `.keyboardShortcut` doesn't register globally on macOS, so the panel
    /// needs its own key handling that calls the same method).
    func toggleExpanded() {
        guard !selection.selectedIDs.isEmpty else { return }
        selection.toggleExpanded(ids: selection.selectedIDs)
    }

    func startEditingIfSingleSelected() {
        guard !isShowingLogbook,
              selection.selectedIDs.count == 1,
              let id = selection.selectedIDs.first,
              let note = store.activeNotes.first(where: { $0.id == id }) else { return }
        selection.beginEditing(id: id, text: note.text)
    }

    /// Opens the single selected note in its own window. Any in-progress
    /// inline edit is committed first, so the window opens on the text the
    /// user can actually see rather than a stale snapshot.
    ///
    /// Posts rather than calling the window manager: those windows are owned
    /// app-wide by `AppDelegate`, which the panel has no handle on (the same
    /// reason `.nickelClosePanel` exists).
    func editInNewWindow() {
        commitActiveEditIfAny()
        guard !isShowingLogbook,
              selection.selectedIDs.count == 1,
              let id = selection.selectedIDs.first,
              store.activeNotes.contains(where: { $0.id == id }) else { return }
        NotificationCenter.default.post(name: .nickelEditNoteInNewWindow, object: id)
    }

    /// Commits whatever note is currently mid-edit (if any) and exits edit
    /// mode. Called before selection-mutating actions (clicking another row,
    /// clicking the background) so the previously-edited note's text is
    /// guaranteed saved before that row's `TextField` is torn down — its own
    /// `.onChange(of: editFocus)` commit can otherwise race a same-tick
    /// selection change.
    func commitActiveEditIfAny() {
        guard let id = selection.editingID else { return }
        store.update(id: id, text: selection.editingText)
        selection.endEditing()
    }

    func merge() {
        guard !isShowingLogbook, selection.selectedIDs.count >= 2 else { return }
        let mergedID = selectedNotes.min(by: { $0.createdAt < $1.createdAt })?.id
        store.merge(ids: selection.selectedIDs)
        if let mergedID {
            selection.selectSingle(mergedID)
        } else {
            selection.clear()
        }
    }

    /// Deletes the current selection, then selects the nearest surviving
    /// note (standard `NSTableView` behavior): the note that followed the
    /// last deleted note in the pre-delete visible order, or (if none
    /// follows) the note that preceded the first deleted one, or (if the
    /// list is now empty) nothing.
    func delete() {
        guard !selection.selectedIDs.isEmpty else { return }
        // In the Logbook, ⌫ means "delete permanently", which always asks
        // first (see `PanelView`'s confirmation dialog).
        guard !isShowingLogbook else {
            requestPermanentDelete(ids: selection.selectedIDs)
            return
        }
        // Snapshot both before mutating: `SelectionModel` prunes its
        // selection synchronously when the store's notes change, so reading
        // `selectedIDs` (or the computed `visibleOrder`) after the delete
        // would see post-delete state.
        let deletedIDs = selection.selectedIDs
        let order = selection.visibleOrder
        let deletedIndices = order.indices.filter { deletedIDs.contains(order[$0]) }
        let lastDeletedIndex = deletedIndices.max()
        let firstDeletedIndex = deletedIndices.min()

        store.delete(ids: deletedIDs)

        let survivors = order.filter { !deletedIDs.contains($0) }
        var nextSelectionID: UUID?
        if let lastDeletedIndex {
            if let after = order[(lastDeletedIndex + 1)...].first(where: { survivors.contains($0) }) {
                nextSelectionID = after
            } else if let firstDeletedIndex {
                nextSelectionID = order[..<firstDeletedIndex].last { survivors.contains($0) }
            }
        }

        if let nextSelectionID {
            selection.selectSingle(nextSelectionID)
        } else {
            selection.clear()
        }
    }

    // MARK: - Logbook

    /// Moves the current selection to the Logbook — the soft, recoverable
    /// counterpart to `delete()` (row context menu's "Move to Logbook",
    /// ⌥⌫). No confirmation, since "Put Back" in the Logbook undoes it.
    /// Selection pruning is handled generically by `SelectionModel` once the
    /// notes leave `activeNotes`, the same way `delete()`'s removals are.
    func moveToLogbook() {
        guard !isShowingLogbook, !selection.selectedIDs.isEmpty else { return }
        store.archive(ids: selection.selectedIDs)
    }

    /// Puts archived notes back in the list (the Logbook's "Put Back").
    func restore(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        store.restore(ids: ids)
    }

    /// Stages the "Delete Permanently…" confirmation; `confirmPermanentDelete`
    /// is what actually deletes. Both the row context menu and ⌫ come through
    /// here, so the confirmation can never be bypassed.
    func requestPermanentDelete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        selection.permanentDeleteConfirmation = ids
    }

    func confirmPermanentDelete() {
        guard let ids = selection.permanentDeleteConfirmation else { return }
        selection.permanentDeleteConfirmation = nil
        store.deletePermanently(ids: ids)
    }

    // MARK: - Move to list

    func move(toSection sectionName: String?) {
        guard !isShowingLogbook, !selection.selectedIDs.isEmpty else { return }
        store.move(ids: selection.selectedIDs, toSection: sectionName)
    }

    /// Creates a new section immediately with a provisional name (Finder's
    /// "New Folder" pattern), moves the current selection into it, and puts
    /// its section header into inline rename mode so the user can type over
    /// the provisional name right away.
    func createSectionWithSelection() {
        guard !isShowingLogbook, !selection.selectedIDs.isEmpty else { return }
        let name = store.uniqueProvisionalSectionName()
        store.move(ids: selection.selectedIDs, toSection: name)
        selection.beginRenamingSection(name)
    }

    // MARK: - Section commands

    /// The ⋯ menu's (and the ⌘K palette's) "New Section": creates a
    /// provisional section — which also switches to it, via `createSection` —
    /// and puts its header into inline rename mode so the user can type over
    /// the provisional name right away (Finder's "New Folder" pattern).
    func createAndRenameNewSection() {
        let name = store.uniqueProvisionalSectionName()
        store.createSection(named: name)
        selection.beginRenamingSection(name)
    }

    func renameActiveSection() {
        guard let activeSection = store.activeSection else { return }
        selection.beginRenamingSection(activeSection)
    }

    func dissolveActiveSection() {
        guard let activeSection = store.activeSection else { return }
        store.dissolveSection(activeSection)
    }

    func requestDeleteActiveSection() {
        guard let activeSection = store.activeSection else { return }
        requestDeleteSection(activeSection)
    }

    /// Deletes `name` immediately if it has no notes (Finder-like — nothing
    /// to lose, so no confirmation), otherwise stages
    /// `selection.sectionDeleteConfirmation` so `PanelView`'s dialog can
    /// offer moving the notes to the Logbook (the default) or deleting them.
    ///
    /// The note count comes from `store.activeNotes` directly (not the
    /// filtered, visible notes) so the dialog always reflects the section's
    /// real contents regardless of an active search.
    func requestDeleteSection(_ name: String) {
        let count = store.activeNotes.filter { $0.listName == name }.count
        guard count > 0 else {
            store.deleteSection(name)
            return
        }
        selection.sectionDeleteConfirmation = SectionDeleteConfirmation(name: name, noteCount: count)
    }

    /// "Clear Done", scoped the way the ⋯ menu's item is: the active section
    /// if one is focused, otherwise everywhere.
    func clearDoneInScope() {
        store.clearDone()
    }

    func clearDoneInActiveSection() {
        guard let activeSection = store.activeSection else { return }
        store.clearDone(in: activeSection)
    }

    func openLogbook() {
        selection.setShowingLogbook(true)
    }

    func openSettings() {
        SettingsWindowController.shared.show()
    }

    // MARK: - Right-click

    /// Right-clicking a note that isn't already selected selects only it,
    /// leaving an existing multi-selection intact if the clicked note is
    /// already part of it.
    ///
    /// Also resigns text focus (composer/search field), matching the
    /// single-click case — unless this is a right-click on the note already
    /// mid-inline-edit, which shouldn't yank focus out of its own field.
    func selectOnRightClick(_ id: UUID) {
        if selection.editingID != id {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        if !selection.selectedIDs.contains(id) {
            selection.selectSingle(id)
        }
    }
}
