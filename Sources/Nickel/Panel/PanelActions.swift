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
        let byID = Dictionary(uniqueKeysWithValues: store.notes.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    var allSelectedAreDone: Bool {
        let notes = selectedNotes
        return !notes.isEmpty && notes.allSatisfy(\.isDone)
    }

    // MARK: - Copy

    func copy() {
        PasteboardWriter.copy(notes: selectedNotes)
    }

    func copyAsList() {
        PasteboardWriter.copyAsList(notes: selectedNotes)
    }

    func copyAllAsList() {
        PasteboardWriter.copyAsList(notes: allVisibleNotes)
    }

    // MARK: - Done / edit / merge / delete

    func toggleDone() {
        guard !selection.selectedIDs.isEmpty else { return }
        store.toggleDone(ids: selection.selectedIDs)
    }

    func startEditingIfSingleSelected() {
        guard selection.selectedIDs.count == 1,
              let id = selection.selectedIDs.first,
              let note = store.notes.first(where: { $0.id == id }) else { return }
        selection.beginEditing(id: id, text: note.text)
    }

    func merge() {
        guard selection.selectedIDs.count >= 2 else { return }
        let mergedID = selectedNotes.min(by: { $0.createdAt < $1.createdAt })?.id
        store.merge(ids: selection.selectedIDs)
        selection.selectedIDs = mergedID.map { [$0] } ?? []
    }

    func delete() {
        guard !selection.selectedIDs.isEmpty else { return }
        store.delete(ids: selection.selectedIDs)
        selection.clear()
    }

    // MARK: - Move to list

    func move(toList listName: String?) {
        guard !selection.selectedIDs.isEmpty else { return }
        store.move(ids: selection.selectedIDs, toList: listName)
    }

    /// Creates a new list immediately with a provisional name (Finder's
    /// "New Folder" pattern), moves the current selection into it, and puts
    /// its section header into inline rename mode so the user can type over
    /// the provisional name right away.
    func createListWithSelection() {
        guard !selection.selectedIDs.isEmpty else { return }
        let name = store.uniqueProvisionalListName()
        store.move(ids: selection.selectedIDs, toList: name)
        selection.renamingListName = name
    }

    // MARK: - Right-click

    /// Right-clicking a note that isn't already selected selects only it,
    /// leaving an existing multi-selection intact if the clicked note is
    /// already part of it.
    func selectOnRightClick(_ id: UUID) {
        if !selection.selectedIDs.contains(id) {
            selection.selectSingle(id)
        }
    }
}
