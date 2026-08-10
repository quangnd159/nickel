import Combine
import Foundation
import SwiftUI

/// A panel-wide modal overlay: the ⌘K section palette or the ⌘/ keyboard
/// shortcuts card. At most one is presented at a time.
///
/// `sectionSwitcher`'s `move` flag is snapshotted once, at presentation time
/// (see `PanelView`'s `.nickelToggleSectionSwitcher` handler), rather than
/// derived live from `selectedIDs` while the palette is open: the palette's
/// own commit handling can clear/leave the selection mid-interaction, and a
/// live read would risk the palette silently flipping mode out from under
/// the user while it's open.
enum PanelOverlay: Equatable {
    case sectionSwitcher(move: Bool)
    case shortcuts
}

/// A request to scroll a given note into view, raised only by keyboard
/// navigation (never clicks or select-all — AppKit's `NSTableView` doesn't
/// auto-scroll for those either). `token` is regenerated on every request so
/// repeated arrow presses that land on the same lead row (e.g. hitting the
/// top/bottom boundary) still produce a distinct `Equatable` value and fire
/// `.onChange`.
struct RevealRequest: Equatable {
    let id: UUID
    let token = UUID()
}

/// A pending "Delete Section…" confirmation: which section, and how many
/// notes it holds (captured at request time, for the dialog's message — see
/// `PanelActions.requestDeleteSection`).
struct SectionDeleteConfirmation: Identifiable, Equatable {
    let name: String
    let noteCount: Int
    var id: String { name }
}

/// Shared selection/editing state for the note list, plus the click and
/// keyboard-navigation logic that operates over the panel's current flat
/// visible (filtered, grouped) order of notes.
final class SelectionModel: ObservableObject {
    /// `SelectionModel` and `NoteStore` are both created once, in
    /// `FloatingPanel`'s init, and live for the app's lifetime — there's no
    /// ownership cycle to worry about (the store doesn't hold a reference
    /// back), so a plain strong `let` is simpler than `unowned`/`weak` and
    /// carries no dangling-reference risk.
    private let store: NoteStore
    private var cancellables: Set<AnyCancellable> = []

    @Published var selectedIDs: Set<UUID> = []
    @Published var editingID: UUID?
    @Published var editingText: String = ""

    /// The search box's live text. Lives here rather than as `PanelView`
    /// `@State` because both rendering (`filteredNotes`) and selection
    /// (`visibleOrder`) need to derive from it, and putting it on the same
    /// object as the derivation keeps the two from ever reading different
    /// snapshots of "what's currently filtered".
    @Published var searchText: String = ""

    /// The overlay currently presented over the panel, if any. Lives here
    /// (rather than as `@State` in `PanelView`) so `FloatingPanel` — which
    /// owns this object — can consult it directly from its `keyDown`
    /// override and route Esc to closing the overlay instead of the panel's
    /// own selection-clear/hide handling. `PanelView` sets it in response to
    /// the `.nickelToggleSectionSwitcher` / `.nickelToggleShortcuts`
    /// notifications posted by `FloatingPanel.performKeyEquivalent`.
    @Published var presentedOverlay: PanelOverlay?

    /// True while the Logbook (cleared notes) has taken over the panel's
    /// content area. Lives here — like `presentedOverlay` — so `FloatingPanel`
    /// can consult it from its own key handling, where Esc returns to the
    /// list and ⌫ means "delete permanently".
    @Published private(set) var isShowingLogbook = false

    /// Notes staged for the Logbook's "Delete Permanently…" confirmation;
    /// `nil` when nothing is pending. Set by both the row context menu and
    /// ⌫ (which is handled in `FloatingPanel`, hence the shared state rather
    /// than `PanelView` `@State`), read by `PanelView`'s confirmation dialog.
    @Published var permanentDeleteConfirmation: Set<UUID>?

    /// The section staged for the three-button "Delete Section…"
    /// confirmation; `nil` when nothing is pending. Lives here — like
    /// `permanentDeleteConfirmation` — because both the section header's
    /// context menu and the ⌘K palette raise it, and neither can reach
    /// `PanelView`'s own state. Read by `PanelView`'s confirmation dialog.
    @Published var sectionDeleteConfirmation: SectionDeleteConfirmation?

    /// Notes currently showing full (untruncated) text in the list, rather
    /// than the default 3-line clamp — session-only (not persisted to the
    /// store), toggled via the context menu's "Expand"/"Collapse" or ⌘E.
    @Published var expandedIDs: Set<UUID> = []

    /// The section name currently in inline section-header rename mode, if
    /// any (set by `PanelActions.createSectionWithSelection()` for a
    /// just-created section, by the ⋯ menu's "New Section", or by
    /// double-clicking/context-menuing a header in `PanelView`).
    @Published var renamingSectionName: String?

    /// Live edit buffer for whichever section header is currently in inline
    /// rename mode. Set together with `renamingSectionName` by
    /// `beginRenamingSection(_:)` so the two are never observed out of sync
    /// (avoids a one-frame window where `HeaderRenameField` is created bound
    /// to an empty string before a separate sync pass fills it in).
    @Published var renameText: String = ""

    /// Set only by keyboard navigation (`moveSelection`) and by expansion
    /// (`toggleExpanded`), never by clicks or select-all, so `PanelView` can
    /// scroll the affected row into view the way `NSTableView` keyboard nav
    /// and Finder's expand-a-folder disclosure would — and only then.
    @Published private(set) var revealRequest: RevealRequest?

    /// Name of the coordinate space `PanelView` attaches to the note list's
    /// scroll viewport, so rows can report viewport-relative frames.
    static let viewportSpaceName = "noteListViewport"

    /// Each visible row's current frame in the viewport coordinate space,
    /// kept up to date by `NoteRow`. Deliberately not `@Published` — frames
    /// change on every scroll tick and nothing renders from them; they're
    /// read on demand (e.g. deciding whether entering an edit needs a
    /// coordinated scroll).
    var rowViewportFrames: [UUID: CGRect] = [:]

    /// The last note explicitly clicked or navigated to; the anchor for
    /// shift-click and shift-arrow range selection.
    private var anchorID: UUID?

    /// The moving end of the current range selection (the last note reached
    /// by shift-arrow or shift-click). Arrow keys step from here, not from
    /// the anchor — otherwise repeated shift-arrows could never grow the
    /// range past the anchor's immediate neighbor.
    private var leadID: UUID?

    init(store: NoteStore) {
        self.store = store

        // Selection/anchor/lead/editing state is pruned when a note stops
        // *existing* in the store, not when it merely scrolls out of the
        // current search filter — a note temporarily hidden by a search
        // shouldn't lose its selection the moment you start typing, and
        // should still be there (selected) if you clear the search again.
        // `visibleOrder` itself is computed fresh below, never stored, so
        // there's no separate copy that can lag a store mutation by a frame.
        store.$notes
            .sink { [weak self] notes in
                guard let self else { return }
                // "Exists" means "exists in the list currently on screen":
                // clearing a done note archives rather than deletes it, so
                // it leaves the list without leaving `notes` — and a note
                // that's no longer visible must not stay selected, or ⌫
                // would act on something the user can't see.
                let inScope = notes.filter { ($0.archivedAt != nil) == self.isShowingLogbook }
                self.pruneToExisting(ids: Set(inScope.map(\.id)))
            }
            .store(in: &cancellables)
    }

    private func pruneToExisting(ids: Set<UUID>) {
        selectedIDs = selectedIDs.intersection(ids)
        if let anchorID, !ids.contains(anchorID) {
            self.anchorID = nil
        }
        if let leadID, !ids.contains(leadID) {
            self.leadID = nil
        }
        if let editingID, !ids.contains(editingID) {
            endEditing()
        }
    }

    // MARK: - Visible order derivation

    /// The notes the panel is currently showing at all, before search: the
    /// Logbook's cleared notes while it's open, otherwise the live ones.
    private var scopedNotes: [Note] {
        isShowingLogbook ? store.archivedNotes : store.activeNotes
    }

    /// Notes matching `searchText` (case-insensitive substring over the
    /// note's text and its attachments' filenames), or all of `scopedNotes`
    /// when the search field is empty. The single source both `PanelView`'s
    /// rendering and `visibleOrder` below filter from, so the two can never
    /// diverge.
    var filteredNotes: [Note] {
        guard !searchText.isEmpty else { return scopedNotes }
        return scopedNotes.filter { note in
            note.text.localizedCaseInsensitiveContains(searchText)
                || note.attachments.contains { $0.filename.localizedCaseInsensitiveContains(searchText) }
        }
    }

    /// One filter pass, grouped by section. Computed on demand like
    /// `filteredNotes` — never stored — so it can't lag the store.
    var filteredNotesBySection: [String?: [Note]] {
        Dictionary(grouping: filteredNotes, by: \.listName)
    }

    /// `filteredNotes` scoped to one section, or the ungrouped notes when
    /// `section` is `nil`.
    func notes(in section: String?) -> [Note] {
        filteredNotesBySection[section] ?? []
    }

    /// The flat, filtered, visible order of note IDs, matching the note
    /// list's display order exactly: just the active section's notes when
    /// one is focused, otherwise ungrouped notes first, then each section's
    /// notes. Computed on demand (not cached) so it's always in step with
    /// the store — no pushed-copy sync to fall a frame behind a mutation.
    var visibleOrder: [UUID] {
        // The Logbook is one flat, newest-cleared-first list (its day
        // headers only break up that same order), not a sectioned one.
        if isShowingLogbook { return filteredNotes.map(\.id) }

        let grouped = filteredNotesBySection
        if let activeSection = store.activeSection {
            return (grouped[activeSection] ?? []).map(\.id)
        }
        var ids = (grouped[String?.none] ?? []).map(\.id)
        for sectionName in store.sections {
            ids += (grouped[sectionName] ?? []).map(\.id)
        }
        return ids
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
        leadID = id
    }

    func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        anchorID = id
        leadID = id
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
        leadID = id
    }

    /// Click on empty space: clears the selection.
    func clear() {
        selectedIDs = []
        anchorID = nil
        leadID = nil
    }

    // MARK: - Keyboard navigation

    /// Moves (or extends) the selection by `direction` (+1 down, -1 up)
    /// through the flat visible order.
    func moveSelection(direction: Int, extend: Bool) {
        guard !visibleOrder.isEmpty else { return }

        guard let referenceID = leadID ?? anchorID ?? selectedIDs.first,
              let currentIndex = visibleOrder.firstIndex(of: referenceID) else {
            let entryID = direction < 0 ? visibleOrder[visibleOrder.count - 1] : visibleOrder[0]
            selectSingle(entryID)
            revealRequest = RevealRequest(id: entryID)
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

        // Always raise a reveal request for the (possibly unchanged) lead
        // row, including at the top/bottom boundary: `NSTableView` keeps the
        // selected row visible on every arrow press, and re-requesting the
        // same row is harmless (`ScrollViewReader.scrollTo` is a no-op if
        // it's already on screen) while skipping it would leave a boundary
        // row that scrolled out of view via some other means (e.g. a resize)
        // stranded off-screen.
        revealRequest = RevealRequest(id: newID)
    }

    // MARK: - Inline editing

    func beginEditing(id: UUID, text: String) {
        // Same spring as `endEditing`, so opening into edit and collapsing
        // back out are one continuous motion (the editor keeps the caret
        // revealed while the row grows — see `InlineNoteEditorField`).
        withAnimation(.noteRowSpring) {
            editingID = id
            editingText = text
        }
    }

    func endEditing() {
        // Ending an edit collapses the row back to its preview and reflows
        // everything below; the list's shared spring keeps that motion
        // trackable. Beginning an edit deliberately stays instant — the
        // editor must be typeable immediately, and the caret reveal
        // measures final layout, which an in-flight animation would break.
        withAnimation(.noteRowSpring) {
            editingID = nil
            editingText = ""
        }
    }

    // MARK: - Section rename

    /// Enters inline rename mode for a section header, seeding the edit
    /// buffer *before* flipping on `renamingSectionName` so the field is
    /// never rendered with stale/empty text.
    func beginRenamingSection(_ name: String) {
        renameText = name
        renamingSectionName = name
    }

    func endRenamingSection() {
        renamingSectionName = nil
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
            // Expansion grows the row downward, so a note near the viewport
            // bottom would disclose its content off-screen; reveal it the
            // way Finder's outline view reveals newly disclosed children.
            // Collapse needs no reveal — the row only shrinks.
            if let target = leadID.flatMap({ ids.contains($0) ? $0 : nil }) ?? ids.first {
                revealRequest = RevealRequest(id: target)
            }
        }
    }

    // MARK: - Logbook

    /// Opens or closes the Logbook. Either way the selection is dropped and
    /// any in-progress edit ends: the two views list different notes, so
    /// carrying selection across would leave rows selected out of sight.
    func setShowingLogbook(_ isShowing: Bool) {
        guard isShowingLogbook != isShowing else { return }
        clear()
        endEditing()
        permanentDeleteConfirmation = nil
        withAnimation(.noteRowSpring) {
            isShowingLogbook = isShowing
        }
    }

    // MARK: - Select all

    func selectAllNotes() {
        guard !visibleOrder.isEmpty else { return }
        selectedIDs = Set(visibleOrder)
        anchorID = visibleOrder.first
        leadID = visibleOrder.last
    }
}
