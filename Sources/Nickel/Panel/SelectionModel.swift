import Combine
import Foundation
import SwiftUI

/// A panel-wide modal overlay: the section palette (switch or move mode) or
/// the ⌘/ keyboard shortcuts card. At most one is presented at a time.
///
/// `sectionSwitcher`'s `move` flag is fixed by which entry point opened the
/// palette — ⌘K always opens switch mode, ⌃⌘M ("Move to Section…") always
/// opens move mode — rather than derived from `selectedIDs`: see
/// `PanelView.toggleSectionSwitcher`/`toggleMoveToSection`.
enum PanelOverlay: Equatable {
    case sectionSwitcher(move: Bool)
    case shortcuts
}

/// A request to scroll a given note into view, raised when expanding a row
/// discloses content that would otherwise open below the viewport — never by
/// clicks, select-all or the arrows, which the table already handles. `token`
/// is regenerated on every request so two requests for the same row still
/// produce distinct `Equatable` values and are both acted on.
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

/// Shared selection/editing state for the note list, and the derivation of
/// the panel's current flat visible (filtered, grouped) order of notes.
///
/// `selectedIDs` is the app-facing source of truth every command reads, but
/// the *input* that changes it — click, ⇧-click, ⌘-click, arrows, ⌘A — belongs
/// to the list's `NSTableView`, which bridges its native selection back here
/// (see `NoteListCoordinator`).
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

    /// True while the composer's field editor holds first responder *and* the
    /// panel is the key window — i.e. while the composer is the focused
    /// control the user is typing into.
    ///
    /// Owned here, and written only by `FloatingPanel`, because the window is
    /// the only place that sees every way focus can be lost. The field itself
    /// can't: AppKit hands a focused `NSTextField` straight to the window's
    /// field editor and calls `textDidEndEditing` only when editing actually
    /// *ends* — when the panel merely stops being key (the user clicks another
    /// app or another Nickel window), the field editor stays first responder
    /// and no callback ever fires. `FloatingPanel.makeFirstResponder` /
    /// `becomeKey` / `resignKey` cover all of it.
    @Published private(set) var isComposerFocused = false

    func setComposerFocused(_ isFocused: Bool) {
        guard isComposerFocused != isFocused else { return }
        isComposerFocused = isFocused
    }

    /// True while the search field's field editor holds first responder
    /// *and* the panel is the key window — the same signal as
    /// `isComposerFocused`, one field over. Drives the search capsule's
    /// substitute focus ring, since `SearchField` suppresses AppKit's own
    /// ring the same way `ComposerField` does.
    ///
    /// Owned here for the same reason as `isComposerFocused`: written only by
    /// `FloatingPanel`, the one place that sees every way focus can be lost.
    @Published private(set) var isSearchFocused = false

    func setSearchFocused(_ isFocused: Bool) {
        guard isSearchFocused != isFocused else { return }
        isSearchFocused = isFocused
    }

    /// Notes staged for the Logbook's "Delete Permanently" confirmation;
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

    /// A row the list should scroll into view. Raised by expansion
    /// (`toggleExpanded`), never by clicks or select-all — arrow-key
    /// navigation doesn't need it either, since `NSTableView` keeps the lead
    /// row visible on its own.
    @Published private(set) var revealRequest: RevealRequest?

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

        // A selection is scoped to whatever section is on screen; carrying it
        // across a section change (⇧⌘]/⇧⌘[, the ⋯ menu, a ⌘K switch, "Show
        // All") would leave notes selected that have scrolled out of view or
        // aren't even the section being looked at. Routed through this one
        // subscription — rather than a `clear()` call at every call site
        // that can change `activeSection` — so it can never be missed.
        store.$activeSection
            .dropFirst()
            .sink { [weak self] _ in
                self?.clear()
            }
            .store(in: &cancellables)
    }

    private func pruneToExisting(ids: Set<UUID>) {
        selectedIDs = selectedIDs.intersection(ids)
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

    // MARK: - Programmatic selection
    //
    // Click, ⇧-click, ⌘-click, the arrows and ⇧-arrows are all
    // `NSTableView`'s now (see `NoteListTable`), which is also where the
    // anchor/lead bookkeeping range selection needs lives. What's left here is
    // the selection *state* the rest of the app reads, plus the few places
    // that set it outright.

    /// Replaces the selection with one note — after a merge, after a delete
    /// picks the nearest survivor, and when a double-click opens an edit.
    func selectSingle(_ id: UUID) {
        selectedIDs = [id]
    }

    /// Click on empty space, Escape, or a section/Logbook switch.
    func clear() {
        selectedIDs = []
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
            if let target = visibleOrder.last(where: { ids.contains($0) }) {
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

    /// Backs ⌘A when the list itself doesn't have focus (the Edit menu's
    /// Select All targets the window then). With the list focused, the table
    /// handles ⌘A natively and this state follows through the bridge.
    func selectAllNotes() {
        guard !visibleOrder.isEmpty else { return }
        selectedIDs = Set(visibleOrder)
    }
}
