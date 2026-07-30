import SwiftUI

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
}

struct PanelView: View {
    @EnvironmentObject private var store: NoteStore
    @StateObject private var ui = PanelUIState()

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow)

            VStack(spacing: 0) {
                topBar
                    .padding(.bottom, 10)

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
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                TextField("Search", text: $ui.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary)
            )

            Menu {
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

    private var noteList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(ungroupedNotes) { note in
                    NoteRow(note: note) { store.toggleDone(ids: [note.id]) }
                }

                ForEach(store.listNames, id: \.self) { listName in
                    let items = notes(in: listName)
                    if !items.isEmpty {
                        sectionHeader(listName)
                            .padding(.top, 12)

                        ForEach(items) { note in
                            NoteRow(note: note) { store.toggleDone(ids: [note.id]) }
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()

            Rectangle()
                .fill(.tertiary)
                .frame(height: 1)
        }
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)

            TextField("Add a note or a prompt", text: $ui.composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .onSubmit(commitComposer)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
    }

    private func commitComposer() {
        let text = ui.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.add(text: text, sourceApp: nil)
        ui.composerText = ""
    }
}
