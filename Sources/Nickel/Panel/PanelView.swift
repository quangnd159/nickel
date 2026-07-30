import SwiftUI
import ServiceManagement

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.state = .active
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

struct PanelView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions
    @State private var searchText = ""
    @State private var composerText = ""

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

                if store.notes.isEmpty && searchText.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    noteList
                }

                composer
                    .padding(.top, 10)
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onAppear { selection.updateVisibleOrder(flatVisibleIDs) }
        .onChange(of: flatVisibleIDs) { _, newValue in selection.updateVisibleOrder(newValue) }
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
                Button("Copy All as List") {
                    actions.copyAllAsList()
                }

                Divider()

                Toggle("Launch at Login", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { LaunchAtLogin.setEnabled($0) }
                ))

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

    private func notes(in listName: String) -> [Note] {
        filteredNotes.filter { $0.listName == listName }
    }

    /// The flat, filtered, visible order of note IDs (ungrouped first, then
    /// each list's notes), matching `noteList`'s display order exactly.
    /// `SelectionModel` uses this for range selection and arrow-key nav.
    private var flatVisibleIDs: [UUID] {
        var ids = ungroupedNotes.map(\.id)
        for listName in store.listNames {
            ids += notes(in: listName).map(\.id)
        }
        return ids
    }

    private var noteList: some View {
        GeometryReader { geometry in
            ScrollView {
                ZStack(alignment: .top) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { handleBackgroundClick() }

                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(ungroupedNotes) { note in
                            NoteRow(note: note) { store.toggleDone(ids: [note.id]) }
                                .transition(rowTransition)
                        }

                        ForEach(store.listNames, id: \.self) { listName in
                            let items = notes(in: listName)
                            if !items.isEmpty {
                                sectionHeader(listName)
                                    .padding(.top, 12)
                                    .transition(rowTransition)

                                ForEach(items) { note in
                                    NoteRow(note: note) { store.toggleDone(ids: [note.id]) }
                                        .transition(rowTransition)
                                }
                            }
                        }
                    }
                    .animation(rowSpring, value: flatVisibleIDs)
                    // Expand/collapse changes a row's height without adding
                    // or removing it from `flatVisibleIDs`, so it needs its
                    // own `.animation` keyed off `expandedIDs` to pick up the
                    // same spring.
                    .animation(rowSpring, value: selection.expandedIDs)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
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

    private func sectionHeader(_ listName: String) -> some View {
        let isRenaming = selection.renamingListName == listName

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
                        onCommit: { commitHeaderRename(from: listName) },
                        onCancel: { selection.endRenamingList() }
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
                Text(listName.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { selection.beginRenamingList(listName) }
            }

            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
        .contextMenu {
            Button("Rename List") { selection.beginRenamingList(listName) }
            Button("Dissolve List") { dissolveList(listName) }
        }
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
        store.renameList(from: oldName, to: selection.renameText)
        selection.endRenamingList()
    }

    /// Notes survive; the list grouping disappears (all matching notes'
    /// `listName` is cleared). Uses the full (unfiltered) note set so a
    /// search filter doesn't leave stray notes behind in the dissolved list.
    private func dissolveList(_ listName: String) {
        let ids = Set(store.notes.filter { $0.listName == listName }.map(\.id))
        store.move(ids: ids, toList: nil)
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(.quaternary)
                .frame(height: 19)

            ComposerField(text: $composerText, onCommit: commitComposer)
                .font(.system(size: 14))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
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

    private func commitComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.add(text: text, sourceApp: nil)
        composerText = ""
    }
}
