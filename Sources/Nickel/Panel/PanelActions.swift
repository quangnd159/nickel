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

    /// Shows a small modal prompt (NSAlert + accessory text field) for a new
    /// list name, then moves the selection into it. This is the simplest
    /// reliable way to get a one-line text prompt without SwiftUI `@State`
    /// driven sheet plumbing.
    func promptNewList() {
        guard !selection.selectedIDs.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "New List"
        alert.informativeText = "Enter a name for the new list."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.placeholderString = "List name"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        move(toList: name)
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
