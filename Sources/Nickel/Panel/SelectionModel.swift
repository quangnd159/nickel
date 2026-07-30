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

    /// The list name currently in inline section-header rename mode, if any
    /// (set by `PanelActions.createListWithSelection()` for a just-created
    /// list, or by double-clicking/context-menuing a header in
    /// `PanelView`).
    @Published var renamingListName: String?

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
            selectSingle(visibleOrder[0])
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
}
