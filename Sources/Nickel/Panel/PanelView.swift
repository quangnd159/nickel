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

/// Holds the panel's ephemeral UI state (search text, composer draft).
///
/// This is a plain `ObservableObject` wired up via `@StateObject` rather than
/// `@State`, because the `@State` property-wrapper macro requires a compiler
/// plugin (`SwiftUIMacros`) that ships only with Xcode.app. This project is
/// built with the Xcode Command Line Tools only (`swift build`, no Xcode), so
/// that plugin isn't available and `@State` fails to compile. `@StateObject`
/// has no such macro dependency and works fine here.
final class PanelUIState: ObservableObject {
    @Published var searchText = ""
    @Published var composerText = ""

    /// Live edit buffer for whichever section header is currently in inline
    /// rename mode (see `SelectionModel.renamingListName`), kept here rather
    /// than in `SelectionModel` since it's pure ephemeral UI state local to
    /// this view.
    @Published var headerRenameText = ""
}

struct PanelView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions
    @StateObject private var ui = PanelUIState()

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
            .onTapGesture { selection.clear() }

            VStack(spacing: 0) {
                topBar
                    .padding(.bottom, 12)

                if store.notes.isEmpty && ui.searchText.isEmpty {
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
        .onChange(of: selection.renamingListName) { _, newValue in
            if let newValue { ui.headerRenameText = newValue }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                SearchField(text: $ui.searchText, onEscape: handleSearchEscape)
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
        guard !ui.searchText.isEmpty else { return store.notes }
        return store.notes.filter { $0.text.localizedCaseInsensitiveContains(ui.searchText) }
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
        ScrollView {
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selection.clear() }

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
            }
        }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selection.clear() }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                HeaderRenameField(
                    text: Binding(
                        get: { ui.headerRenameText },
                        set: { ui.headerRenameText = $0 }
                    ),
                    onCommit: { commitHeaderRename(from: listName) },
                    onCancel: { selection.renamingListName = nil }
                )
                .font(.system(size: 11, weight: .semibold))
                .fixedSize()
            } else {
                Text(listName.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginRenamingList(listName) }
            }

            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
        .contextMenu {
            Button("Rename List") { beginRenamingList(listName) }
            Button("Dissolve List") { dissolveList(listName) }
        }
    }

    private func beginRenamingList(_ listName: String) {
        ui.headerRenameText = listName
        selection.renamingListName = listName
    }

    private func commitHeaderRename(from oldName: String) {
        store.renameList(from: oldName, to: ui.headerRenameText)
        selection.renamingListName = nil
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
            Text("Double-tap Shift anywhere to capture")
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

            TextField("Add a note or a prompt", text: $ui.composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...5)
                .onSubmit(commitComposer)
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
        if !ui.searchText.isEmpty {
            ui.searchText = ""
        } else {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func commitComposer() {
        let text = ui.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.add(text: text, sourceApp: nil)
        ui.composerText = ""
    }
}
