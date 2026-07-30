import Foundation

/// Shared selection/editing state for the note list, plus the click and
/// keyboard-navigation logic that operates over the panel's current flat
/// visible (filtered, grouped) order of notes.
///
/// Plain `ObservableObject` (not `@State`) per this project's constraint: the
/// `@State` macro needs the `SwiftUIMacros` compiler plugin, which isn't
/// available under `swift build` without Xcode.app.
final class SelectionModel: ObservableObject {
    @Published var selectedIDs: Set<UUID> = []
    @Published var editingID: UUID?
    @Published var editingText: String = ""

    /// Notes currently showing full (untruncated) text in the list, rather
    /// than the default 3-line clamp — session-only (not persisted to the
    /// store), toggled via the context menu's "Expand"/"Collapse" or ⌘E.
    @Published var expandedIDs: Set<UUID> = []

    /// The list name currently in inline section-header rename mode, if any
    /// (set by `PanelActions.createListWithSelection()` for a just-created
    /// list, or by double-clicking/context-menuing a header in
    /// `PanelView`).
    @Published var renamingListName: String?

    /// Live edit buffer for whichever section header is currently in inline
    /// rename mode. Set together with `renamingListName` by
    /// `beginRenamingList(_:)` so the two are never observed out of sync
    /// (avoids a one-frame window where `HeaderRenameField` is created bound
    /// to an empty string before a separate sync pass fills it in).
    @Published var renameText: String = ""

    /// The panel's current flat, filtered, visible order of note IDs
    /// (ungrouped notes first, then each list's notes, in display order).
    /// Kept in sync by `PanelView` whenever the underlying/filtered note list
    /// changes.
    private(set) var visibleOrder: [UUID] = []

    /// The last note explicitly clicked or navigated to; the anchor for
    /// shift-click and shift-arrow range selection.
    private var anchorID: UUID?

    func updateVisibleOrder(_ order: [UUID]) {
        visibleOrder = order
        selectedIDs = selectedIDs.intersection(order)
        if let anchorID, !order.contains(anchorID) {
            self.anchorID = nil
        }
        if let editingID, !order.contains(editingID) {
            endEditing()
        }
    }

    // MARK: - Click handling

    /// Single entry point for a click on a note card; `shift`/`command`
    /// reflect the modifier keys held at click time.
    func handleClick(on id: UUID, shift: Bool, command: Bool) {
        if shift {
            if anchorID == nil {
                selectSingle(id)
            } else {
                extendRange(to: id)
            }
        } else if command {
            toggle(id)
        } else {
            selectSingle(id)
        }
    }

    func selectSingle(_ id: UUID) {
        selectedIDs = [id]
        anchorID = id
    }

    func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        anchorID = id
    }

    private func extendRange(to id: UUID) {
        guard let anchorID,
              let anchorIndex = visibleOrder.firstIndex(of: anchorID),
              let targetIndex = visibleOrder.firstIndex(of: id) else {
            selectSingle(id)
            return
        }
        let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        selectedIDs = Set(visibleOrder[range])
        // Anchor stays put so further shift-clicks keep extending from the same origin.
    }

    /// Click on empty space: clears the selection.
    func clear() {
        selectedIDs = []
        anchorID = nil
    }

    // MARK: - Keyboard navigation

    /// Moves (or extends) the selection by `direction` (+1 down, -1 up)
    /// through the flat visible order.
    func moveSelection(direction: Int, extend: Bool) {
        guard !visibleOrder.isEmpty else { return }

        guard let referenceID = anchorID ?? selectedIDs.first,
              let currentIndex = visibleOrder.firstIndex(of: referenceID) else {
            selectSingle(direction < 0 ? visibleOrder[visibleOrder.count - 1] : visibleOrder[0])
            return
        }

        let newIndex = min(max(currentIndex + direction, 0), visibleOrder.count - 1)
        let newID = visibleOrder[newIndex]

        if extend {
            if anchorID == nil {
                anchorID = referenceID
            }
            extendRange(to: newID)
        } else {
            selectSingle(newID)
        }
    }

    // MARK: - Inline editing

    func beginEditing(id: UUID, text: String) {
        editingID = id
        editingText = text
    }

    func endEditing() {
        editingID = nil
        editingText = ""
    }

    // MARK: - List rename

    /// Enters inline rename mode for a section header, seeding the edit
    /// buffer *before* flipping on `renamingListName` so the field is never
    /// rendered with stale/empty text.
    func beginRenamingList(_ name: String) {
        renameText = name
        renamingListName = name
    }

    func endRenamingList() {
        renamingListName = nil
        renameText = ""
    }

    // MARK: - Expand / collapse

    /// Toggles the expanded state of `ids` as a group: if every one of them
    /// is currently expanded, collapses them all; otherwise expands them
    /// all. Matches the "Mark as Done" toggle's all-or-nothing convention.
    func toggleExpanded(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: expandedIDs) {
            expandedIDs.subtract(ids)
        } else {
            expandedIDs.formUnion(ids)
        }
    }

    // MARK: - Select all

    func selectAllNotes() {
        guard !visibleOrder.isEmpty else { return }
        selectedIDs = Set(visibleOrder)
        anchorID = visibleOrder.first
    }
}
