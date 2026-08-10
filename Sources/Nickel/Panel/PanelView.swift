import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

/// Posted by `FloatingPanel` when ⌘V is pressed and the pasteboard holds
/// file/image content but no plain text, so `PanelView` can stage those as
/// pending composer attachments instead of the paste falling through as a
/// normal (empty) text paste.
extension Notification.Name {
    static let nickelComposerPaste = Notification.Name("NickelComposerPaste")
}

/// Posted by the ⋯ menu's "Close" item so `FloatingPanel` can hide itself via
/// its normal animated toggle path, without `PanelView` needing a direct
/// reference back to the panel that hosts it.
extension Notification.Name {
    static let nickelClosePanel = Notification.Name("NickelClosePanel")
}

extension View {
    /// The panel's single elevation treatment: a soft drop shadow that lifts
    /// a control off the background material. Shared by the search capsule,
    /// the ⋯ button, the composer card, and the floating pills so they all
    /// sit at the same apparent height.
    func panelElevation() -> some View {
        shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        // Native windows dim their material when they're not the active
        // window; `.active` would freeze the focused look permanently.
        view.state = .followsWindowActiveState
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// A file/image the user has picked, dropped, or pasted but not yet
/// committed to a note — shown as a chip above the composer's text field.
/// `sourceURL` may point at the original file (paperclip picker, drag) or a
/// temp file Nickel itself wrote (a pasted/dropped raw image payload).
struct StagedAttachment: Identifiable {
    let id = UUID()
    var sourceURL: URL
    var filename: String
    var contentType: String
}

struct PanelView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions
    @State private var composerText = ""
    @State private var pendingAttachments: [StagedAttachment] = []
    /// The composer's staged destination-section chip. See
    /// `ComposerSectionChip` for the staging/removal logic; `stageSection`
    /// and `removeStagedSection` below are what the "#" suggestion popup
    /// calls when a row is accepted.
    @State private var sectionChip = ComposerSectionChip()
    /// The "#…" query Esc last dismissed the suggestion popup at, or `nil`
    /// when nothing is dismissed. The popup itself has no state of its own:
    /// its rows are derived from the composer text, the chip, the sections,
    /// and this — see `ComposerSectionSuggestions.visibleRows`.
    @State private var dismissedSuggestionQuery: String?
    /// The suggestion popup's highlighted row. Clamped when read, so a
    /// shrinking result set can never point past the end.
    @State private var suggestionHighlight = 0
    @State private var isComposerDropTargeted = false
    /// The transient "Attached N file(s)" confirmation shown above the
    /// composer after a drop, paperclip pick, or ⌘V paste stages new
    /// attachments; `nil` when nothing is showing. See `showAttachmentToast`.
    @State private var attachmentToast: String?
    /// Cancelled and rescheduled by `showAttachmentToast` so back-to-back
    /// stagings (e.g. dropping a few files right after pasting one) restart
    /// the auto-dismiss timer instead of an old one hiding the new toast
    /// early.
    @State private var attachmentToastDismissTask: DispatchWorkItem?
    @Environment(\.controlActiveState) private var controlActiveState

    /// Corner radius of the composer card. Larger than a note row's so the
    /// tallest control in the panel stays visually concentric inside the
    /// 30pt window, matching Copper's proportions.
    private static let composerCornerRadius: CGFloat = 24

    /// Resting height of the composer card: twice the search capsule's 32pt,
    /// so an empty composer already reads as a roomy text area inviting a
    /// longer note rather than a padded single-line field. The content row
    /// sits at the top and the growing field expands past this on its own.
    private static let composerMinHeight: CGFloat = 64

    /// Distance from the composer row's leading edge (inside its own 16pt
    /// padding) to the text field's leading edge: the circle glyph's
    /// rendered width (19pt, same assumption `NoteRow` makes about its own
    /// checkbox glyph) plus the 12pt gap to the field. Used to indent the
    /// chip row so its leading edge lines up with the composer text rather
    /// than the circle.
    private static let composerTextLeadingInset: CGFloat = 19 + 12

    /// The composer's focus ring follows AppKit: only while the field
    /// actually holds focus and the panel is the key window (both folded into
    /// `selection.isComposerFocused`), and never while a drag is targeted (the
    /// dashed drop border takes over there).
    private var showsComposerFocusRing: Bool {
        selection.isComposerFocused && !isComposerDropTargeted
    }

    var body: some View {
        ZStack {
            ZStack {
                VisualEffectBackground(material: .popover)

                // Mutes wallpaper bleed from the effect view above: a
                // near-solid gray wash so the panel reads as a soft, opaque
                // surface (Copper's look) rather than a translucent HUD,
                // while still adapting to dark mode via
                // `.windowBackgroundColor`.
                Color(nsColor: .windowBackgroundColor).opacity(0.62)
            }
            .contentShape(Rectangle())
            .onTapGesture { handleBackgroundClick() }

            VStack(spacing: 0) {
                topBar
                    .padding(.bottom, 12)

                // The global empty state only applies in Show All: with an
                // active section, the pinned header + per-section hint must
                // show even when there are no notes anywhere yet (e.g. the
                // user's very first action was staging a "#" section chip).
                if selection.isShowingLogbook {
                    LogbookView()
                        .transition(sectionSwitchTransition)
                } else if store.activeNotes.isEmpty && selection.searchText.isEmpty && store.activeSection == nil {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    noteList
                }

                if let saveError = store.saveError {
                    saveErrorBanner(saveError)
                        .padding(.top, 10)
                }

                // No composer in the Logbook: it's a record of cleared
                // notes, not somewhere new ones are captured.
                if !selection.isShowingLogbook {
                    composer
                        .padding(.top, 10)
                        .transition(sectionSwitchTransition)
                        // Keeps the composer's "#" suggestion popup drawing
                        // over the note list above it.
                        .zIndex(1)
                }
            }
            .padding(16)

            // Overlays: at most one presented at a time (see
            // `SelectionModel.presentedOverlay`), each dimming/covering
            // everything above. A quick fade+scale reads as "instant" without
            // being an abrupt cut.
            if case .sectionSwitcher(let move) = selection.presentedOverlay {
                SectionSwitcher(move: move)
                    .transition(sectionSwitchTransition)
            }

            if selection.presentedOverlay == .shortcuts {
                ShortcutsOverlay()
                    .transition(sectionSwitchTransition)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .onReceive(NotificationCenter.default.publisher(for: .nickelToggleSectionSwitcher)) { _ in
            toggleSectionSwitcher()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nickelToggleShortcuts)) { _ in
            toggleOverlay(.shortcuts)
        }
        .onReceive(NotificationCenter.default.publisher(for: .nickelComposerPaste)) { _ in
            stagePasteboardAttachments()
        }
        .confirmationDialog(
            "Delete Section",
            isPresented: Binding(
                get: { selection.sectionDeleteConfirmation != nil },
                set: { isPresented in if !isPresented { selection.sectionDeleteConfirmation = nil } }
            ),
            presenting: selection.sectionDeleteConfirmation
        ) { confirmation in
            // The recoverable choice is the default one, so Return can never
            // fire the destructive button.
            Button("Move Notes to Logbook") {
                store.archiveSection(confirmation.name)
                selection.sectionDeleteConfirmation = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Delete Notes", role: .destructive) {
                store.deleteSection(confirmation.name)
                selection.sectionDeleteConfirmation = nil
            }
            Button("Cancel", role: .cancel) {
                selection.sectionDeleteConfirmation = nil
            }
        } message: { confirmation in
            Text(confirmation.noteCount == 1
                 ? "“\(confirmation.name)” has 1 note. It can move to the Logbook or be deleted."
                 : "“\(confirmation.name)” has \(confirmation.noteCount) notes. They can move to the Logbook or be deleted.")
        }
        // The Logbook's "Delete Permanently" (context menu or ⌫). Staged on
        // `SelectionModel` rather than local `@State` because ⌫ is handled in
        // `FloatingPanel`, which can't reach this view's state.
        .confirmationDialog(
            "Delete Permanently",
            isPresented: Binding(
                get: { selection.permanentDeleteConfirmation != nil },
                set: { isPresented in if !isPresented { selection.permanentDeleteConfirmation = nil } }
            ),
            presenting: selection.permanentDeleteConfirmation
        ) { _ in
            Button("Delete", role: .destructive) {
                actions.confirmPermanentDelete()
            }
            Button("Cancel", role: .cancel) {
                selection.permanentDeleteConfirmation = nil
            }
        } message: { ids in
            Text(ids.count == 1
                 ? "Delete this note permanently? This can't be undone."
                 : "Delete these \(ids.count) notes permanently? This can't be undone.")
        }
    }

    /// Opens `overlay`, or closes it if it's already the one presented
    /// (⌘K/⌘/ both toggle); opening either one always replaces the other, so
    /// only one is ever presented at a time.
    private func toggleOverlay(_ overlay: PanelOverlay) {
        withAnimation(.panelOverlay) {
            selection.presentedOverlay = (selection.presentedOverlay == overlay) ? nil : overlay
        }
    }

    /// ⌘K's toggle: closes the palette if it's already open (in either
    /// mode), otherwise opens it fresh with `move` snapshotted from whether
    /// anything is selected *right now* — see the `move` doc comment on
    /// `PanelOverlay.sectionSwitcher`. Kept separate from `toggleOverlay`
    /// (rather than passed a computed `PanelOverlay` there) because that
    /// generic helper's equality-based toggle would treat re-pressing ⌘K
    /// with a since-changed selection as "opening a different overlay"
    /// instead of closing the one that's open.
    private func toggleSectionSwitcher() {
        withAnimation(.panelOverlay) {
            if case .sectionSwitcher = selection.presentedOverlay {
                selection.presentedOverlay = nil
            } else {
                // Logbook rows can't be moved into a section (see
                // `PanelActions.move`), so a selection there mustn't open the
                // palette in move mode — ⌘K stays the switch-and-command
                // palette, and picking a destination leaves the Logbook.
                let move = !selection.isShowingLogbook && !selection.selectedIDs.isEmpty
                selection.presentedOverlay = .sectionSwitcher(move: move)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .accessibilityHidden(true)

                SearchField(text: $selection.searchText, onEscape: handleSearchEscape)
                    .font(.system(size: 13))
                    .accessibilityLabel("Search")
            }
            // A capsule rather than a rounded rect, and nearly opaque, so it
            // reads as a raised control sitting on the panel's material
            // instead of a well cut into it.
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.85))
                    .panelElevation()
            )

            Menu {
                // Picking a destination leaves the Logbook, exactly as the ⌘K
                // palette's destination rows do (see `SectionSwitcher.commit`)
                // — switching the section behind the Logbook would otherwise
                // change a list the user can't see.
                Section("Section") {
                    Toggle("Show All", isOn: Binding(
                        get: { store.activeSection == nil && !selection.isShowingLogbook },
                        set: { isOn in
                            guard isOn else { return }
                            selection.setShowingLogbook(false)
                            store.setActiveSection(nil)
                        }
                    ))

                    ForEach(store.sections, id: \.self) { sectionName in
                        Toggle(sectionName, isOn: Binding(
                            get: { store.activeSection == sectionName && !selection.isShowingLogbook },
                            set: { isOn in
                                guard isOn else { return }
                                selection.setShowingLogbook(false)
                                store.setActiveSection(sectionName)
                            }
                        ))
                    }

                    // The rest of this section acts on the live list, so it's
                    // disabled (menu convention — the items stay in place)
                    // while the Logbook is showing.
                    Button("New Section") { actions.createAndRenameNewSection() }
                        .disabled(selection.isShowingLogbook)

                    Button("Rename Section") { actions.renameActiveSection() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.activeSection == nil || selection.isShowingLogbook)
                }

                Divider()

                Button("Clear Done") {
                    store.clearDone()
                }
                .disabled(!hasDoneNotesInScope || selection.isShowingLogbook)

                // A toggle rather than an "Open Logbook" button, so the item
                // shows which view the panel is in (like the Section toggles
                // above) and doubles as the way back out.
                Toggle("Logbook", isOn: Binding(
                    get: { selection.isShowingLogbook },
                    set: { selection.setShowingLogbook($0) }
                ))

                Button("Copy All as List") {
                    actions.copyAllAsList()
                }

                Button("Reveal Notes in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                }

                Divider()

                Button("Keyboard Shortcuts") {
                    selection.presentedOverlay = .shortcuts
                }

                Divider()

                Section("Window") {
                    Toggle("Keep on Top", isOn: Binding(
                        get: { PanelSettings.keepPanelOnTop },
                        set: { PanelSettings.keepPanelOnTop = $0 }
                    ))

                    Button("Close") {
                        NotificationCenter.default.post(name: .nickelClosePanel, object: nil)
                    }
                }

                Divider()

                Button("Settings…") {
                    SettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)

                Divider()

                Button("Quit Nickel") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // The circle sits behind the whole `Menu`, and the 32pt frame is
            // set out here too: `.borderlessButton` rasterizes the label down
            // to its glyph, so neither a background nor a frame applied
            // inside it survives. Same raised, near-opaque treatment as the
            // search capsule beside it, at the capsule's own 32pt height, so
            // the two read as one control row.
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.85))
                    .panelElevation()
            )
        }
    }

    // MARK: - Note list

    private var noteList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The active section's header is pinned above the scroll
            // content (rather than inline, like the "Show All" headers
            // below) so it stays visible even when the section is empty.
            if let activeSection = store.activeSection {
                sectionHeader(activeSection)
                    .padding(.bottom, 12)
                    .transition(sectionSwitchTransition)
            }

            GeometryReader { geometry in
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        ZStack(alignment: .top) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { handleBackgroundClick() }

                            if let activeSection = store.activeSection {
                                let items = selection.notes(in: activeSection)
                                if items.isEmpty {
                                    emptySectionHint
                                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                                        .transition(sectionSwitchTransition)
                                } else {
                                    // Not lazy: see the comment on the Show All
                                    // `VStack` below for why.
                                    VStack(alignment: .leading, spacing: 10) {
                                        ForEach(items) { note in
                                            NoteRow(note: note) { store.toggleDone(ids: [note.id]) }
                                                .transition(rowTransition)
                                        }
                                    }
                                    .transition(sectionSwitchTransition)
                                    .animation(rowSpring, value: selection.visibleOrder)
                                    .animation(rowSpring, value: selection.expandedIDs)
                                }
                            } else {
                                // Deliberately not lazy: rows migrate between the
                                // ungrouped and per-section ForEach loops when a
                                // note is moved into a section, and LazyVStack's
                                // per-identity cell cache would keep serving the
                                // pre-move Note snapshot (stale done-checkbox).
                                // These lists are small, so laziness buys nothing.
                                let grouped = selection.filteredNotesBySection
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(grouped[String?.none] ?? []) { note in
                                        NoteRow(note: note) { store.toggleDone(ids: [note.id]) }
                                            .transition(rowTransition)
                                    }

                                    // Every section's header renders here, even
                                    // an empty one: with `sections` as the source
                                    // of truth for existence, Show All is where
                                    // an empty section can be found, reordered,
                                    // or deleted. No per-section empty hint
                                    // though — that would clutter a view meant to
                                    // stay a clean overview.
                                    ForEach(store.sections, id: \.self) { sectionName in
                                        sectionHeader(sectionName)
                                            .padding(.top, 12)
                                            .transition(rowTransition)

                                        ForEach(grouped[sectionName] ?? []) { note in
                                            NoteRow(note: note) { store.toggleDone(ids: [note.id]) }
                                                .transition(rowTransition)
                                        }
                                    }
                                }
                                .transition(sectionSwitchTransition)
                                .animation(rowSpring, value: selection.visibleOrder)
                                // Expand/collapse changes a row's height without
                                // adding or removing it from `visibleOrder`, so
                                // it needs its own `.animation` keyed off
                                // `expandedIDs` to pick up the same spring.
                                .animation(rowSpring, value: selection.expandedIDs)
                                // Reordering two sections that are both empty (or
                                // otherwise don't change which note ids are
                                // visible) wouldn't otherwise change
                                // `visibleOrder`, so the headers need their own
                                // animation keyed off section order directly.
                                .animation(rowSpring, value: store.sections)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .coordinateSpace(name: SelectionModel.viewportSpaceName)
                    // Keyboard navigation (arrow keys) keeps the lead row
                    // visible, matching `NSTableView.scrollRowToVisible`: no
                    // anchor (scrolls the minimal distance to the nearest
                    // edge) and no animation (AppKit's keyboard-nav scrolling
                    // is instant). Clicks and select-all don't set
                    // `revealRequest`, so they don't trigger this.
                    .onChange(of: selection.revealRequest) { _, request in
                        guard let request else { return }
                        scrollProxy.scrollTo(request.id)
                    }
                    // Entering an edit grows the row to its full text (the
                    // preview is clamped to 3 lines); when that growth would
                    // run past the viewport bottom, scroll in the same
                    // spring the growth animates with, so the card opens and
                    // the list glides in one coordinated motion with the
                    // caret's end-of-note position landing on screen. Rows
                    // that still fit don't scroll at all. Height is
                    // estimated from the note's text (`editedRowHeight`);
                    // the editor's own deferred reveal backstops any
                    // estimate error.
                    .onChange(of: selection.editingID) { _, editingID in
                        guard let editingID,
                              let note = store.activeNotes.first(where: { $0.id == editingID }),
                              let rowFrame = selection.rowViewportFrames[editingID] else { return }
                        let finalBottom = rowFrame.minY + editedRowHeight(text: note.text, rowWidth: rowFrame.width)
                        guard finalBottom > geometry.size.height else { return }
                        // Deferred a turn: issued directly in `onChange`,
                        // `scrollTo` computes its target from the row's
                        // pre-growth layout and lands short. One turn later
                        // the layout is final, and the scroll's spring still
                        // overlaps the growth's almost entirely.
                        DispatchQueue.main.async {
                            withAnimation(.noteRowSpring) {
                                scrollProxy.scrollTo(editingID, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        // Drives both the pinned header's appearance/disappearance and the
        // swap between the focused-section view and "Show All" with the same
        // spring used for row insert/delete/move, so switching sections
        // (menu, ⌘K, or a composer "#" chip) animates instead of
        // hard-cutting. The
        // composer/search bar don't move: `noteList` already fills a fixed
        // slice of the outer `VStack`, so the header's appearance only
        // resizes the `GeometryReader` below it, not the panel around it.
        .animation(rowSpring, value: store.activeSection)
    }

    /// Shown below the pinned header when the active section has no notes
    /// yet (empty, but distinct from "no notes anywhere" — see `emptyState`).
    private var emptySectionHint: some View {
        Text("Notes you capture will be saved here")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
    }

    /// Gentle spring used for note insert/delete/move and section
    /// appearance, keyed off the flat visible order so any change to which
    /// notes are shown (or in what order) animates.
    private var rowSpring: Animation { .noteRowSpring }

    /// Estimated on-screen height of `text`'s row once inline editing shows
    /// the full text: the text measured at the row's content width (row
    /// minus 14pt horizontal padding each side, the 19pt checkbox, and its
    /// 12pt gap) plus the 13pt vertical padding each side. Matches the
    /// editor's own metrics (`InlineNoteEditorField.textAttributes`); used
    /// only to decide whether entering the edit needs a coordinated scroll,
    /// so small error is fine — the editor's deferred reveal corrects it.
    private func editedRowHeight(text: String, rowWidth: CGFloat) -> CGFloat {
        let textWidth = max(rowWidth - 28 - 19 - 12, 50)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        let textHeight = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .paragraphStyle: style,
        ]).boundingRect(
            with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).height
        return ceil(textHeight) + 26
    }

    private var rowTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
    }

    /// Used for the pinned header and the list content it swaps with when
    /// `store.activeSection` changes, subtler than `rowTransition` since it's
    /// covering a whole-view swap rather than a single row.
    private var sectionSwitchTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }

    private func sectionHeader(_ sectionName: String) -> some View {
        let isRenaming = selection.renamingSectionName == sectionName

        return HStack(spacing: 8) {
            if isRenaming {
                ZStack(alignment: .leading) {
                    // Invisible sizing text: makes the ZStack's width track
                    // the live edit buffer, so the field auto-grows/shrinks
                    // with typing instead of sitting at a fixed width.
                    Text(selection.renameText.isEmpty ? " " : selection.renameText)
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0)
                        .fixedSize()

                    HeaderRenameField(
                        text: Binding(
                            get: { selection.renameText },
                            set: { selection.renameText = $0 }
                        ),
                        onCommit: { commitHeaderRename(from: sectionName) },
                        onCancel: { selection.endRenamingSection() }
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                }
                .frame(minWidth: 60, maxWidth: 240, alignment: .leading)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
            } else {
                Text(sectionName.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { selection.beginRenamingSection(sectionName) }
            }

            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
        .contextMenu {
            Button("Rename Section") { selection.beginRenamingSection(sectionName) }

            Divider()

            Button("Move Up") { store.moveSection(sectionName, offset: -1) }
                .disabled(store.sections.first == sectionName)
            Button("Move Down") { store.moveSection(sectionName, offset: 1) }
                .disabled(store.sections.last == sectionName)

            Divider()

            Button("Clear Done in Section") { store.clearDone(in: sectionName) }
                .disabled(!hasDoneNotes(inSection: sectionName))

            Divider()

            // Dissolve keeps the notes (ungrouping them) and never asks;
            // Delete Section… also keeps the notes by default (moving them to
            // the Logbook) but offers permanent deletion as the destructive
            // alternative in its confirmation — kept as separate,
            // clearly-labeled items rather than one "Delete" that's
            // ambiguous about which it means.
            Button("Dissolve Section") { store.dissolveSection(sectionName) }

            Button("Delete Section…", role: .destructive) {
                actions.requestDeleteSection(sectionName)
            }
        }
    }

    private func hasDoneNotes(inSection name: String) -> Bool {
        store.activeNotes.contains { $0.isDone && $0.listName == name }
    }

    /// Shared empty-area click handler: resigns first responder (which
    /// commits any in-progress header rename, Finder-style, via its
    /// `textDidEndEditing` path) then explicitly commits any in-progress note
    /// edit and clears the selection.
    ///
    /// Note edit commit is explicit rather than relying solely on
    /// `makeFirstResponder(nil)`: the note editor is now a SwiftUI
    /// `TextField` with `@FocusState`, which AppKit's `makeFirstResponder`
    /// doesn't reliably resign (SwiftUI manages its own focus state
    /// independently of the responder chain in some cases), so `NoteRow`'s
    /// `.onChange(of: editFocus)` commit path isn't guaranteed to fire here.
    private func handleBackgroundClick() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        actions.commitActiveEditIfAny()
        selection.clear()
    }

    private func commitHeaderRename(from oldName: String) {
        store.renameSection(from: oldName, to: selection.renameText)
        selection.endRenamingSection()
    }

    /// Whether there's at least one done note in the current scope (the
    /// active section if one is set, otherwise anywhere) — used to disable
    /// the ⋯ menu's "Clear Done" when there's nothing for it to do.
    private var hasDoneNotesInScope: Bool {
        if let activeSection = store.activeSection {
            return store.activeNotes.contains { $0.isDone && $0.listName == activeSection }
        }
        return store.activeNotes.contains(where: \.isDone)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Double-tap left Shift anywhere to capture")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text("Captured text and quick notes will show up here")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sectionChip.name != nil || !pendingAttachments.isEmpty {
                pendingChipsRow
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "circle")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(.quaternary)
                    .frame(height: 19)
                    .accessibilityHidden(true)

                ComposerField(
                    text: $composerText,
                    onCommit: commitComposer,
                    onDeleteBackwardAtStart: removeStagedSectionIfPresent,
                    onMoveHighlight: moveSuggestionHighlight,
                    onAcceptSuggestion: acceptHighlightedSuggestion,
                    onEscape: dismissSuggestions
                )
                    .font(.system(size: 14))
                    .accessibilityLabel("Add a note")

                Button(action: presentAttachmentPicker) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        // Dimmed rather than removed while a drag is targeted, so the
        // "Drop to attach" pill below floats over the composer's normal
        // contents (Copper's look) instead of replacing them — the card
        // never resizes as a drag enters or leaves.
        .opacity(isComposerDropTargeted ? 0.35 : 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(minHeight: Self.composerMinHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Self.composerCornerRadius, style: .continuous)
                .fill(isComposerDropTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .textBackgroundColor))
                .panelElevation()
        )
        // Stands in for the field's own suppressed focus ring
        // (`ComposerField` sets `.focusRingType = .none`) so the ring follows
        // the card rather than the bare text. Full-strength accent rather
        // than `keyboardFocusIndicatorColor` (accent at half alpha): the
        // selected-note stroke is already full accent, and two weights of
        // the same blue in one view read as an inconsistency, not a
        // hierarchy. Centered on the card's edge — half over the control,
        // half over what's behind — which is also how AppKit draws rings.
        .overlay(
            RoundedRectangle(cornerRadius: Self.composerCornerRadius, style: .continuous)
                .stroke(Color(nsColor: .controlAccentColor), lineWidth: 3)
                .opacity(showsComposerFocusRing ? 1 : 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.composerCornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .opacity(isComposerDropTargeted ? 1 : 0)
        )
        .overlay {
            if isComposerDropTargeted {
                dropToAttachPill
            }
        }
        .background(
            ComposerDropTarget(
                isTargeted: $isComposerDropTargeted,
                onFileURLs: stageDroppedFiles,
                onText: insertDroppedText,
                onImageData: stageDroppedImageData
            )
        )
        .overlay(alignment: .top) {
            if let attachmentToast {
                attachmentToastView(attachmentToast)
                    .offset(y: -34)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        // The "#" suggestion popup sits above the composer (which lives at
        // the bottom of the panel), floating over the note list without
        // resizing anything.
        //
        // The geometry is deliberately explicit rather than guide-based: the
        // overlay's content is a fixed `suggestionListMaxHeight`-tall box,
        // aligned by the overlay to the card's top edge and then offset up by
        // its own height plus the 8pt gap, so the box's bottom edge lands
        // exactly 8pt above the card. The popup is bottom-aligned inside that
        // box and hugs its rows (`fixedSize`), so a shorter list grows
        // downward from the top of the box and its bottom edge stays put —
        // the composer's text and chip row are never covered. The empty part
        // of the box draws nothing and takes no clicks.
        .overlay(alignment: .top) {
            if !suggestionRows.isEmpty {
                sectionSuggestionPopup
                    .frame(height: Self.suggestionListMaxHeight, alignment: .bottom)
                    .offset(y: -(Self.suggestionListMaxHeight + 8))
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: suggestionRows.isEmpty)
        .onChange(of: composerText) { _, newText in
            suggestionHighlight = 0
            dismissedSuggestionQuery = ComposerSectionSuggestions.dismissalAfterTextChange(
                text: newText,
                hasStagedSection: sectionChip.name != nil,
                dismissedQuery: dismissedSuggestionQuery
            )
        }
    }

    // MARK: - "#" section suggestions

    /// Height budget for the popup's scrolling list: about six rows (a 13pt
    /// row plus its padding and the 2pt inter-row gap) before it scrolls,
    /// plus the list's own 6pt padding top and bottom.
    private static let suggestionRowHeight: CGFloat = 29
    private static let suggestionListMaxHeight: CGFloat = suggestionRowHeight * 6 + 12

    private var suggestionRows: [ComposerSectionSuggestion] {
        ComposerSectionSuggestions.visibleRows(
            text: composerText,
            isComposerFocused: selection.isComposerFocused,
            hasStagedSection: sectionChip.name != nil,
            sections: store.sections,
            dismissedQuery: dismissedSuggestionQuery
        )
    }

    /// The highlighted index, clamped into the current rows.
    private var highlightedSuggestionIndex: Int {
        min(max(suggestionHighlight, 0), max(suggestionRows.count - 1, 0))
    }

    /// The Spotlight-style list of destination sections shown while the
    /// composer holds a bare "#…" line. Deliberately an in-panel overlay, not
    /// a window or popover: it has to feel like part of the composer, and it
    /// must never take first responder away from the text field.
    private var sectionSuggestionPopup: some View {
        let rows = suggestionRows
        let highlighted = highlightedSuggestionIndex

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        // A real `Button` (not a tap gesture) so each row is
                        // a control to VoiceOver; `.plain` keeps the popup's
                        // own row styling intact.
                        Button {
                            acceptSuggestion(row, refocusingComposer: true)
                        } label: {
                            suggestionRow(row, isHighlighted: index == highlighted)
                        }
                        .buttonStyle(.plain)
                        .id(row.id)
                        .onHover { isHovering in
                            if isHovering { suggestionHighlight = index }
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // `fixedSize` after the cap is what makes the list hug its rows:
            // a `ScrollView` handed a concrete height proposal takes all of
            // it, so without this a two-row popup would still be six rows
            // tall. With a nil proposal it reports its content's height, and
            // the cap above clamps that to six rows (scrolling past them).
            .frame(maxHeight: Self.suggestionListMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlighted) { _, newIndex in
                guard rows.indices.contains(newIndex) else { return }
                proxy.scrollTo(rows[newIndex].id)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
        // Flatten first: every other `panelElevation()` in the panel sits on
        // a filled `Capsule`/`RoundedRectangle`, so it blurs one silhouette.
        // Here it's applied to the popup's content, and an unflattened shadow
        // is cast by each rendered leaf — which drew a blurred copy of every
        // row's own text behind it.
        .compositingGroup()
        .panelElevation()
    }

    /// One popup row, matching `SectionSwitcher`'s rows: the same accent
    /// highlight (unemphasized behind an inactive panel), and the same
    /// "New Section: “…”" wording for the create row.
    private func suggestionRow(_ row: ComposerSectionSuggestion, isHighlighted: Bool) -> some View {
        let isEmphasized = controlActiveState == .key
        let usesAccentFill = isHighlighted && isEmphasized

        return HStack(spacing: 8) {
            Text(suggestionLabel(row))
                .font(.system(size: 13))
                .foregroundStyle(usesAccentFill ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary)
                .lineLimit(1)
                // Tail, like the ⌘K palette: a list of section names reads
                // left to right, and their distinguishing start must survive.
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted
                      ? (isEmphasized
                         ? Color(nsColor: .selectedContentBackgroundColor)
                         : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                      : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func suggestionLabel(_ row: ComposerSectionSuggestion) -> String {
        switch row {
        case .existing(let name): return name
        case .create(let name): return "New Section: “\(name)”"
        }
    }

    /// ↓/↑ while the popup is open. Returns whether it was handled, so the
    /// arrow keeps its normal caret behavior when there's no popup.
    private func moveSuggestionHighlight(_ direction: Int) -> Bool {
        let rows = suggestionRows
        guard !rows.isEmpty else { return false }
        suggestionHighlight = ComposerSectionSuggestions.movedHighlight(
            highlightedSuggestionIndex,
            by: direction,
            count: rows.count
        )
        return true
    }

    /// Return/Tab while the popup is open: stage the highlighted row.
    private func acceptHighlightedSuggestion() -> Bool {
        let rows = suggestionRows
        guard rows.indices.contains(highlightedSuggestionIndex) else { return false }
        acceptSuggestion(rows[highlightedSuggestionIndex], refocusingComposer: false)
        return true
    }

    /// Stages `row` as the chip and empties the field, ready for the note's
    /// body. A click has to hand focus back to the text field afterwards; a
    /// keystroke never lost it.
    private func acceptSuggestion(_ row: ComposerSectionSuggestion, refocusingComposer: Bool) {
        stageSection(named: row.name)
        composerText = ComposerSectionSuggestions.textAfterAcceptance
        dismissedSuggestionQuery = nil
        suggestionHighlight = 0
        if refocusingComposer {
            NotificationCenter.default.post(name: .nickelFocusComposer, object: nil)
        }
    }

    /// Esc while the popup is open: close it and keep the literal text, so
    /// "#hashtag" stays typeable. Returns whether it was handled, so Esc
    /// keeps its existing meaning when no popup is showing.
    private func dismissSuggestions() -> Bool {
        guard !suggestionRows.isEmpty,
              let query = ComposerSectionSuggestions.query(in: composerText, hasStagedSection: sectionChip.name != nil)
        else { return false }
        dismissedSuggestionQuery = query
        return true
    }

    /// Floated over the composer's (dimmed, still-visible) contents while a
    /// drag is targeted at it, mirroring Copper's "Drop to attach" pill.
    private var dropToAttachPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
            Text("Drop to attach")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(.regularMaterial)
                .panelElevation()
        )
    }

    /// The "Attached N file(s)" confirmation pill, floated just above the
    /// composer via its `.overlay(alignment: .top)`.
    private func attachmentToastView(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(.regularMaterial)
                .panelElevation()
        )
    }

    /// Persistent warning shown while the most recent notes.json write has
    /// failed (`store.saveError`). Unlike `attachmentToastView`, this isn't
    /// auto-dismissing `@State`: it's driven by store state and clears
    /// itself only when a save succeeds.
    private func saveErrorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Couldn't save notes: \(message)")
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.2))
        )
    }

    /// Shared shell for the composer's staged chips (section destination and
    /// attachments): same capsule padding/shape, and a hover-revealed
    /// remove button in the macOS Mail token style — hidden at rest, faded
    /// in over the pointer, never shifting the chip's size. The button
    /// stays in the layout at `.opacity(0)` (rather than being removed)
    /// so the chip's width never changes on hover, and `.allowsHitTesting`
    /// keeps it unclickable while hidden. Because hover is unavailable to
    /// keyboard/VoiceOver users, removal is also exposed as a named
    /// accessibility action on the chip itself.
    private struct ComposerChip<Content: View>: View {
        let fill: AnyShapeStyle
        let accessibilityLabel: String
        let onRemove: () -> Void
        @ViewBuilder let content: () -> Content

        @State private var isHovering = false

        var body: some View {
            HStack(spacing: 6) {
                content()

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .animation(.easeInOut(duration: 0.1), value: isHovering)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
            )
            .onHover { isHovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAction(named: Text("Remove"), onRemove)
        }
    }

    /// The staged section chip and attachment chips, shown together above
    /// the composer's text field. The section chip (at most one) always
    /// leads, so it reads as "where this note is headed" ahead of "what's
    /// attached". Indented by `composerTextLeadingInset` so the row's
    /// leading edge lines up with the composer text, not the circle glyph.
    private var pendingChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let section = sectionChip.name {
                    pendingSectionChip(section)
                }
                ForEach(pendingAttachments) { staged in
                    pendingAttachmentChip(staged)
                }
            }
            .padding(.leading, Self.composerTextLeadingInset)
        }
    }

    /// The staged destination-section chip. A "number" glyph stands in for
    /// the section's own hash-icon elsewhere in the app. The glyph and the
    /// section name are accent-tinted on a faint accent fill, so the chip
    /// reads as destination metadata (a tag) rather than attached content;
    /// an existing-but-not-yet-created section still gets a small secondary
    /// "New" label so the note's destination doesn't look ambiguous before
    /// it commits.
    private func pendingSectionChip(_ section: String) -> some View {
        let isNewSection = !store.sections.contains { $0.caseInsensitiveCompare(section) == .orderedSame }

        return ComposerChip(
            fill: AnyShapeStyle(Color.accentColor.opacity(0.12)),
            accessibilityLabel: isNewSection ? "Destination section, \(section), new" : "Destination section, \(section)",
            onRemove: removeStagedSection
        ) {
            Image(systemName: "number")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)

            Text(section)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120, alignment: .leading)

            if isNewSection {
                Text("New")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// A staged attachment chip: unlike the section chip, stays neutral
    /// (quaternary fill, no tint) since it represents content, not metadata.
    private func pendingAttachmentChip(_ staged: StagedAttachment) -> some View {
        ComposerChip(
            fill: AnyShapeStyle(.quaternary),
            accessibilityLabel: "Attachment, \(staged.filename)",
            onRemove: {
                Self.removeTemporaryStagingDirectory(for: staged.sourceURL)
                pendingAttachments.removeAll { $0.id == staged.id }
            }
        ) {
            AttachmentThumbnailView(fileURL: staged.sourceURL, contentType: staged.contentType, size: 24)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(staged.filename)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120, alignment: .leading)
        }
    }

    /// The composer's paperclip button: opens a standard file picker whose
    /// chosen files become pending attachments. The panel is a
    /// nonactivating panel, so `NSOpenPanel` needs the app explicitly
    /// activated first or it can appear behind other windows; running it
    /// modally (rather than as a sheet) keeps this a simple, synchronous
    /// call like the rest of the panel's AppKit interop.
    private func presentAttachmentPicker() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }
        guard !panel.urls.isEmpty else { return }
        for url in panel.urls {
            pendingAttachments.append(StagedAttachment(sourceURL: url, filename: url.lastPathComponent, contentType: contentType(of: url)))
        }
        showAttachmentToast(count: panel.urls.count)
    }

    /// ⌘V while the pasteboard has attachable content (file URLs always win
    /// over accompanying text; raw images only when there's no text — see
    /// `FloatingPanel`'s `.nickelComposerPaste` post): stages file URLs
    /// directly, and a raw image payload (e.g. a screenshot) after writing it
    /// to a temp "Image.png" file so it can be copied like any other source
    /// file once the note commits.
    private func stagePasteboardAttachments() {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls {
                pendingAttachments.append(StagedAttachment(sourceURL: url, filename: url.lastPathComponent, contentType: contentType(of: url)))
            }
            showAttachmentToast(count: urls.count)
            return
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           let tempURL = Self.writeTemporaryPNG(image) {
            pendingAttachments.append(StagedAttachment(sourceURL: tempURL, filename: "Image.png", contentType: UTType.png.identifier))
            showAttachmentToast(count: 1)
        }
    }

    // MARK: - Composer drops (see ComposerDropTarget for why AppKit-level)

    /// Dropped files (any type) become pending attachments, exactly like the
    /// paperclip picker and ⌘V paste, leaving `composerText` untouched until
    /// the user commits with Return.
    private func stageDroppedFiles(_ urls: [URL]) {
        for url in urls {
            pendingAttachments.append(StagedAttachment(sourceURL: url, filename: url.lastPathComponent, contentType: contentType(of: url)))
        }
        showAttachmentToast(count: urls.count)
    }

    /// Dropped text content (a dragged selection, not a file) is inserted
    /// into the composer's text — native text-field drop behavior — leaving
    /// Return as the single "commit" gesture.
    private func insertDroppedText(_ text: String) {
        composerText = composerText.isEmpty ? text : composerText + "\n" + text
        NotificationCenter.default.post(name: .nickelFocusComposer, object: nil)
    }

    /// A raw dropped image with no backing file (e.g. a screenshot dragged
    /// straight off a capture tool) is written to a temp "Image.png" file so
    /// it can be copied like any other source file once the note commits.
    private func stageDroppedImageData(_ data: Data) {
        guard let image = NSImage(data: data), let tempURL = Self.writeTemporaryPNG(image) else { return }
        pendingAttachments.append(StagedAttachment(sourceURL: tempURL, filename: "Image.png", contentType: UTType.png.identifier))
        showAttachmentToast(count: 1)
    }

    /// Shows (or restarts) the "Attached N file(s)" toast above the
    /// composer. The dismiss is a cancellable `DispatchWorkItem` rather than
    /// a fixed `Task.sleep` so a second staging while the toast is still up
    /// (e.g. dropping more files right after a paste) restarts the ~1.8s
    /// countdown instead of an earlier dismiss cutting the new toast short.
    private func showAttachmentToast(count: Int) {
        showAttachmentToast(message: count == 1 ? "Attached 1 file" : "Attached \(count) files")
    }

    /// Shown when `commitComposer` couldn't copy one or more staged
    /// attachments into the note's attachments directory; those items stay
    /// staged (see `commitComposer`) rather than being silently discarded.
    private func showAttachmentFailureToast(count: Int) {
        showAttachmentToast(message: count == 1 ? "Couldn't attach 1 file" : "Couldn't attach \(count) files")
    }

    /// Shared toast presentation, used by both the "Attached" success
    /// message and the "Couldn't attach" failure message.
    private func showAttachmentToast(message: String) {
        attachmentToastDismissTask?.cancel()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            attachmentToast = message
        }

        let dismiss = DispatchWorkItem {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                attachmentToast = nil
            }
        }
        attachmentToastDismissTask = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: dismiss)
    }

    /// Resolves one dropped item to a copyable source file: a real file URL
    /// is used as-is; a raw image payload with no backing file is written to
    /// a temp "Image.png" first.
    /// Best-effort UTType identifier for a file on disk, falling back to
    /// generic `public.data` if the filesystem can't say (e.g. the file
    /// vanished between picking/dropping it and reading its metadata).
    private func contentType(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.identifier ?? UTType.data.identifier
    }

    /// Deletes the throwaway temp directory backing a staged raw-image
    /// attachment. Only fires for URLs under the app's temp staging area —
    /// picker/drag sources are the user's real files and must survive.
    private static func removeTemporaryStagingDirectory(for sourceURL: URL) {
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let directory = sourceURL.standardizedFileURL.deletingLastPathComponent()
        guard directory.path.hasPrefix(tempRoot.path + "/") else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            NSLog("PanelView: failed to remove temporary staging directory: \(error)")
        }
    }

    /// Writes `image` out as a standalone PNG in a fresh temp directory (so
    /// concurrent drops/pastes never collide on the same "Image.png" name),
    /// for raw clipboard/drag image payloads that have no backing file of
    /// their own to copy into the note's attachments directory.
    private static func writeTemporaryPNG(_ image: NSImage) -> URL? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("Image.png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pngData.write(to: fileURL)
            return fileURL
        } catch {
            NSLog("PanelView: failed to write temporary image: \(error)")
            return nil
        }
    }

    /// Esc in the search field: if it has text, clear it (and keep focus so
    /// the user can keep typing a new query); if it's already empty, give up
    /// focus so a subsequent Esc falls through to the panel's own Esc
    /// handling (clear selection / hide panel).
    private func handleSearchEscape() {
        if !selection.searchText.isEmpty {
            selection.searchText = ""
        } else {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    /// Return in the composer: commits its text plus any staged attachments
    /// and staged section chip as a new note (or, chip-only, just creates or
    /// switches to that section). See `ComposerCommit.plan` for the decision
    /// logic this drives from.
    private func commitComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch ComposerCommit.plan(text: text, hasAttachments: !pendingAttachments.isEmpty, pendingSection: sectionChip.name) {
        case .noop:
            return

        case .sectionOnly(let section):
            store.createSection(named: section)
            // The field can still hold whitespace here (the trim above is
            // what made this a chip-only commit), so clear it too — otherwise
            // the next note starts with leftover blanks.
            composerText = ""
            sectionChip.remove()

        case .addNote(let section):
            if let section {
                store.createSection(named: section)
            }
            if pendingAttachments.isEmpty {
                store.add(text: text, sourceApp: nil)
            } else {
                let attachments = pendingAttachments.map { (sourceURL: $0.sourceURL, filename: $0.filename, contentType: $0.contentType) }
                let failedIndices = store.add(text: text, attachments: attachments, sourceApp: nil)
                let failed = Set(failedIndices)
                for (index, staged) in pendingAttachments.enumerated() where !failed.contains(index) {
                    Self.removeTemporaryStagingDirectory(for: staged.sourceURL)
                }
                // Items that failed to copy stay staged — their temp files
                // (e.g. a pasted screenshot with no other copy) survive, and
                // the user can retry (Return again) or remove the chip.
                pendingAttachments = failedIndices.compactMap { pendingAttachments.indices.contains($0) ? pendingAttachments[$0] : nil }
                if !failedIndices.isEmpty {
                    showAttachmentFailureToast(count: failedIndices.count)
                }
            }
            composerText = ""
            sectionChip.remove()
        }
        dismissedSuggestionQuery = nil
    }

    /// Stages `name` as the composer's destination-section chip, replacing
    /// any previously staged chip. Called when a "#" suggestion row is
    /// accepted.
    private func stageSection(named name: String) {
        sectionChip.stage(named: name)
    }

    private func removeStagedSection() {
        sectionChip.remove()
    }

    /// ⌫ in the composer with the caret at the very start and nothing
    /// selected: if a section chip is staged, remove it and swallow the
    /// keystroke, rather than doing nothing. Returns whether it was handled,
    /// so `ComposerField` knows whether to fall through to its normal
    /// backspace behavior.
    private func removeStagedSectionIfPresent() -> Bool {
        guard sectionChip.name != nil else { return false }
        removeStagedSection()
        return true
    }
}

/// The note list's one shared row motion. Everything that reflows rows —
/// insert/delete/move, expand/collapse, section changes, and ending an
/// inline edit (`SelectionModel.endEditing`) — uses this same spring so the
/// list moves as one system.
extension Animation {
    static let noteRowSpring = Animation.spring(response: 0.3, dampingFraction: 0.8)

    /// The one motion every panel overlay (⌘K palette, ⌘/ shortcuts card)
    /// appears and disappears with, wherever it's dismissed from — the
    /// toggle, a click on the dim, or Esc handled up in `FloatingPanel`.
    static let panelOverlay = Animation.easeOut(duration: 0.12)
}
