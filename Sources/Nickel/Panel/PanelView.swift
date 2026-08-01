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

/// A pending "Delete Section and Notes…" confirmation: which section, and
/// how many notes it holds (captured at request time, for the dialog's
/// message — see `PanelView.requestDeleteSection`).
private struct SectionDeleteConfirmation: Identifiable {
    let name: String
    let noteCount: Int
    var id: String { name }
}

struct PanelView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions
    @State private var searchText = ""
    @State private var composerText = ""
    @State private var pendingAttachments: [StagedAttachment] = []
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
    /// Staged by the section header's "Delete Section and Notes…" when the
    /// section isn't empty, so the `.confirmationDialog` in `body` can ask
    /// before deleting; `nil` when no confirmation is pending. See
    /// `requestDeleteSection`.
    @State private var sectionDeleteConfirmation: SectionDeleteConfirmation?

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
                // user's very first action was typing "# Name").
                if store.notes.isEmpty && searchText.isEmpty && store.activeSection == nil {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    noteList
                }

                composer
                    .padding(.top, 10)
            }
            .padding(16)

            // Overlays: at most one presented at a time (see
            // `SelectionModel.presentedOverlay`), each dimming/covering
            // everything above. A quick fade+scale reads as "instant" without
            // being an abrupt cut.
            if selection.presentedOverlay == .sectionSwitcher {
                SectionSwitcher()
                    .transition(sectionSwitchTransition)
            }

            if selection.presentedOverlay == .shortcuts {
                ShortcutsOverlay()
                    .transition(sectionSwitchTransition)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onAppear { selection.updateVisibleOrder(flatVisibleIDs) }
        .onChange(of: flatVisibleIDs) { _, newValue in selection.updateVisibleOrder(newValue) }
        .onReceive(NotificationCenter.default.publisher(for: .nickelToggleSectionSwitcher)) { _ in
            toggleOverlay(.sectionSwitcher)
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
                get: { sectionDeleteConfirmation != nil },
                set: { isPresented in if !isPresented { sectionDeleteConfirmation = nil } }
            ),
            presenting: sectionDeleteConfirmation
        ) { confirmation in
            Button("Delete", role: .destructive) {
                store.deleteSection(confirmation.name)
                sectionDeleteConfirmation = nil
            }
            Button("Cancel", role: .cancel) {
                sectionDeleteConfirmation = nil
            }
        } message: { confirmation in
            Text("Delete \"\(confirmation.name)\" and its \(confirmation.noteCount) \(confirmation.noteCount == 1 ? "note" : "notes")?")
        }
    }

    /// Opens `overlay`, or closes it if it's already the one presented
    /// (⌘K/⌘/ both toggle); opening either one always replaces the other, so
    /// only one is ever presented at a time.
    private func toggleOverlay(_ overlay: PanelOverlay) {
        withAnimation(.easeOut(duration: 0.12)) {
            selection.presentedOverlay = (selection.presentedOverlay == overlay) ? nil : overlay
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                SearchField(text: $searchText, onEscape: handleSearchEscape)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
            )

            Menu {
                Section("Section") {
                    Toggle("Show All", isOn: Binding(
                        get: { store.activeSection == nil },
                        set: { isOn in if isOn { store.setActiveSection(nil) } }
                    ))

                    ForEach(store.sections, id: \.self) { sectionName in
                        Toggle(sectionName, isOn: Binding(
                            get: { store.activeSection == sectionName },
                            set: { isOn in if isOn { store.setActiveSection(sectionName) } }
                        ))
                    }

                    Button("New Section") { createAndRenameNewSection() }

                    Button("Rename Section") {
                        if let activeSection = store.activeSection {
                            selection.beginRenamingSection(activeSection)
                        }
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.activeSection == nil)
                }

                Divider()

                Button("Clear Done") {
                    store.clearDone()
                }
                .disabled(!hasDoneNotesInScope)

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
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.quaternary))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - Note list

    private var filteredNotes: [Note] {
        guard !searchText.isEmpty else { return store.notes }
        return store.notes.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    private var ungroupedNotes: [Note] {
        filteredNotes.filter { $0.listName == nil }
    }

    private func notes(in sectionName: String) -> [Note] {
        filteredNotes.filter { $0.listName == sectionName }
    }

    /// The flat, filtered, visible order of note IDs, matching `noteList`'s
    /// display order exactly: just the active section's notes when one is
    /// focused, otherwise ungrouped notes first, then each section's notes.
    /// `SelectionModel` uses this for range selection and arrow-key nav.
    private var flatVisibleIDs: [UUID] {
        if let activeSection = store.activeSection {
            return notes(in: activeSection).map(\.id)
        }
        var ids = ungroupedNotes.map(\.id)
        for sectionName in store.sections {
            ids += notes(in: sectionName).map(\.id)
        }
        return ids
    }

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
                ScrollView {
                    ZStack(alignment: .top) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { handleBackgroundClick() }

                        if let activeSection = store.activeSection {
                            let items = notes(in: activeSection)
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
                                .animation(rowSpring, value: flatVisibleIDs)
                                .animation(rowSpring, value: selection.expandedIDs)
                            }
                        } else {
                            // Deliberately not lazy: rows migrate between the
                            // ungrouped and per-section ForEach loops when a
                            // note is moved into a section, and LazyVStack's
                            // per-identity cell cache would keep serving the
                            // pre-move Note snapshot (stale done-checkbox).
                            // These lists are small, so laziness buys nothing.
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(ungroupedNotes) { note in
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

                                    ForEach(notes(in: sectionName)) { note in
                                        NoteRow(note: note) { store.toggleDone(ids: [note.id]) }
                                            .transition(rowTransition)
                                    }
                                }
                            }
                            .transition(sectionSwitchTransition)
                            .animation(rowSpring, value: flatVisibleIDs)
                            // Expand/collapse changes a row's height without
                            // adding or removing it from `flatVisibleIDs`, so
                            // it needs its own `.animation` keyed off
                            // `expandedIDs` to pick up the same spring.
                            .animation(rowSpring, value: selection.expandedIDs)
                            // Reordering two sections that are both empty (or
                            // otherwise don't change which note ids are
                            // visible) wouldn't otherwise change
                            // `flatVisibleIDs`, so the headers need their own
                            // animation keyed off section order directly.
                            .animation(rowSpring, value: store.sections)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        // Drives both the pinned header's appearance/disappearance and the
        // swap between the focused-section view and "Show All" with the same
        // spring used for row insert/delete/move, so switching sections
        // (menu, ⌘K, or "# Name") animates instead of hard-cutting. The
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
    private var rowSpring: Animation {
        .spring(response: 0.3, dampingFraction: 0.8)
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

            // Dissolve keeps the notes (ungrouping them); Delete removes
            // them too — kept as separate, clearly-labeled items rather than
            // one "Delete" that's ambiguous about which it means.
            Button("Dissolve Section") { store.dissolveSection(sectionName) }

            Button("Delete Section and Notes…", role: .destructive) {
                requestDeleteSection(sectionName)
            }
        }
    }

    /// One item in the section header's context menu: deletes `name`
    /// immediately if it has no notes (Finder-like — nothing to lose, so no
    /// confirmation), otherwise stages `sectionDeleteConfirmation` so the
    /// `.confirmationDialog` in `body` can ask first.
    private func requestDeleteSection(_ name: String) {
        let count = noteCount(inSection: name)
        guard count > 0 else {
            store.deleteSection(name)
            return
        }
        sectionDeleteConfirmation = SectionDeleteConfirmation(name: name, noteCount: count)
    }

    /// Note count for `name`, from `store.notes` directly (not
    /// `filteredNotes`) so the delete confirmation always reflects the
    /// section's real contents regardless of an active search filter.
    private func noteCount(inSection name: String) -> Int {
        store.notes.filter { $0.listName == name }.count
    }

    private func hasDoneNotes(inSection name: String) -> Bool {
        store.notes.contains { $0.isDone && $0.listName == name }
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
            return store.notes.contains { $0.isDone && $0.listName == activeSection }
        }
        return store.notes.contains(where: \.isDone)
    }

    /// The ⋯ menu's "New Section": creates a provisional section (Finder's
    /// "New Folder" pattern) — which also switches to it, via
    /// `createSection` — and puts its header into inline rename mode so the
    /// user can type over the provisional name right away.
    private func createAndRenameNewSection() {
        let name = store.uniqueProvisionalSectionName()
        store.createSection(named: name)
        selection.beginRenamingSection(name)
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
            if !pendingAttachments.isEmpty {
                pendingAttachmentsRow
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "circle")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(.quaternary)
                    .frame(height: 19)

                ComposerField(text: $composerText, onCommit: commitComposer)
                    .font(.system(size: 14))

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
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isComposerDropTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .opacity(isComposerDropTargeted ? 1 : 0)
        )
        .overlay {
            if isComposerDropTargeted {
                dropToAttachPill
            }
        }
        .onDrop(of: composerDropTypes, isTargeted: $isComposerDropTargeted, perform: handleComposerDrop)
        .overlay(alignment: .top) {
            if let attachmentToast {
                attachmentToastView(attachmentToast)
                    .offset(y: -34)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    /// Types accepted by the composer's drop target: real files, raw
    /// image payloads with no backing file (screenshots dragged straight off
    /// a capture tool), and plain text (which is inserted into the composer
    /// text, not staged as an attachment — see `handleComposerDrop`).
    private var composerDropTypes: [UTType] {
        [.fileURL, .image, .png, .tiff, .utf8PlainText, .text]
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
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
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
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        )
    }

    /// The staged-attachment chips shown above the composer's text field.
    private var pendingAttachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { staged in
                    pendingAttachmentChip(staged)
                }
            }
        }
    }

    private func pendingAttachmentChip(_ staged: StagedAttachment) -> some View {
        HStack(spacing: 6) {
            AttachmentThumbnailView(fileURL: staged.sourceURL, contentType: staged.contentType, size: 24)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(staged.filename)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120, alignment: .leading)

            Button(action: { pendingAttachments.removeAll { $0.id == staged.id } }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
        )
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

    /// Handles a drag onto the composer card. Plain text is inserted into
    /// the composer's text (native text-field drop behavior), leaving Return
    /// as the single "commit" gesture; files and images are staged as
    /// pending attachments exactly like the paperclip picker and ⌘V paste,
    /// leaving `composerText` untouched until the user commits with Return.
    private func handleComposerDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        if providers.count == 1, let provider = providers.first,
           provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? String, !text.isEmpty else { return }
                DispatchQueue.main.async {
                    composerText = composerText.isEmpty ? text : composerText + "\n" + text
                    NotificationCenter.default.post(name: .nickelFocusComposer, object: nil)
                }
            }
            return true
        }

        let group = DispatchGroup()
        var collected: [(sourceURL: URL, filename: String, contentType: String)] = []
        let collectedLock = NSLock()

        for provider in providers {
            group.enter()
            loadDroppedAttachment(from: provider) { input in
                if let input {
                    collectedLock.lock()
                    collected.append(input)
                    collectedLock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            guard !collected.isEmpty else { return }
            for input in collected {
                pendingAttachments.append(StagedAttachment(sourceURL: input.sourceURL, filename: input.filename, contentType: input.contentType))
            }
            showAttachmentToast(count: collected.count)
        }
        return true
    }

    /// Shows (or restarts) the "Attached N file(s)" toast above the
    /// composer. The dismiss is a cancellable `DispatchWorkItem` rather than
    /// a fixed `Task.sleep` so a second staging while the toast is still up
    /// (e.g. dropping more files right after a paste) restarts the ~1.8s
    /// countdown instead of an earlier dismiss cutting the new toast short.
    private func showAttachmentToast(count: Int) {
        attachmentToastDismissTask?.cancel()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            attachmentToast = count == 1 ? "Attached 1 file" : "Attached \(count) files"
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
    private func loadDroppedAttachment(
        from provider: NSItemProvider,
        completion: @escaping ((sourceURL: URL, filename: String, contentType: String)?) -> Void
    ) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    completion(nil)
                    return
                }
                completion((sourceURL: url, filename: url.lastPathComponent, contentType: contentType(of: url)))
            }
            return
        }

        let imageTypes: [UTType] = [.png, .tiff, .image]
        guard let imageType = imageTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            completion(nil)
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: imageType.identifier) { data, _ in
            guard let data, let image = NSImage(data: data), let tempURL = Self.writeTemporaryPNG(image) else {
                completion(nil)
                return
            }
            completion((sourceURL: tempURL, filename: "Image.png", contentType: UTType.png.identifier))
        }
    }

    /// Best-effort UTType identifier for a file on disk, falling back to
    /// generic `public.data` if the filesystem can't say (e.g. the file
    /// vanished between picking/dropping it and reading its metadata).
    private func contentType(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.identifier ?? UTType.data.identifier
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
        if !searchText.isEmpty {
            searchText = ""
        } else {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    /// Return in the composer: commits its text plus any staged attachments
    /// as a new note. Either alone is enough (an attachment-only note, or —
    /// as before this feature — plain text), so only both being empty is a
    /// no-op.
    private func commitComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }

        // The "# Name" section shortcut only makes sense for a bare text
        // note; with attachments staged, "#foo" is just note text.
        if pendingAttachments.isEmpty, let command = composerSectionCommandName(text) {
            if let name = command {
                store.createSection(named: name)
                composerText = ""
            }
            // Else: a bare "#" or "# " with nothing typed after it yet — a
            // no-op, leaving the text in place so the user can keep typing.
            return
        }

        if pendingAttachments.isEmpty {
            store.add(text: text, sourceApp: nil)
        } else {
            let attachments = pendingAttachments.map { (sourceURL: $0.sourceURL, filename: $0.filename, contentType: $0.contentType) }
            store.add(text: text, attachments: attachments, sourceApp: nil)
            pendingAttachments = []
        }
        composerText = ""
    }

    /// Recognizes the composer's "# Name" section shortcut. Single line
    /// only: text containing a newline is always a normal note. Returns:
    /// - `nil` if `text` isn't a section command at all (a normal note,
    ///   including a "#hashtag" with no separating space);
    /// - `.some(nil)` for a bare "#"/"# " with no name yet (a no-op);
    /// - `.some(name)` for "# Name" (create-or-switch to `name`).
    private func composerSectionCommandName(_ text: String) -> String?? {
        guard !text.contains("\n"), text.hasPrefix("#") else { return nil }
        let rest = text.dropFirst()
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        let name = rest.trimmingCharacters(in: .whitespaces)
        return .some(name.isEmpty ? nil : name)
    }
}
