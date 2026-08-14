import SwiftUI

/// A section's label + trailing hairline, with double-click-to-rename, the
/// inline rename field, and the section context menu.
///
/// Used two ways: pinned above the list when a section is focused, and as a
/// table group row for each section in Show All. Group-row cells keep their
/// hosting view interactive (unlike note rows), so the double-click, the
/// rename field and this SwiftUI `.contextMenu` all work there unchanged.
struct SectionHeader: View {
    let name: String

    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions

    private var isRenaming: Bool { selection.renamingSectionName == name }

    var body: some View {
        HStack(spacing: 8) {
            if isRenaming {
                renameField
            } else {
                Text(name.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { selection.beginRenamingSection(name) }
            }

            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
        .contextMenu {
            Button("Rename Section") { selection.beginRenamingSection(name) }

            Divider()

            Button("Move Up") { store.moveSection(name, offset: -1) }
                .disabled(store.sections.first == name)
            Button("Move Down") { store.moveSection(name, offset: 1) }
                .disabled(store.sections.last == name)

            Divider()

            Button("Clear Done in Section") { store.clearDone(in: name) }
                .disabled(!hasDoneNotes)

            Divider()

            // Dissolve keeps the notes (ungrouping them) and never asks;
            // Delete Section… also keeps the notes by default (moving them to
            // the Logbook) but offers permanent deletion as the destructive
            // alternative in its confirmation — kept as separate,
            // clearly-labeled items rather than one "Delete" that's
            // ambiguous about which it means.
            Button("Dissolve Section") { store.dissolveSection(name) }

            Button("Delete Section…", role: .destructive) {
                actions.requestDeleteSection(name)
            }
        }
    }

    private var renameField: some View {
        ZStack(alignment: .leading) {
            // Invisible sizing text: makes the ZStack's width track the live
            // edit buffer, so the field auto-grows/shrinks with typing
            // instead of sitting at a fixed width.
            Text(selection.renameText.isEmpty ? " " : selection.renameText)
                .font(.system(size: 11, weight: .semibold))
                .opacity(0)
                .fixedSize()

            HeaderRenameField(
                text: Binding(
                    get: { selection.renameText },
                    set: { selection.renameText = $0 }
                ),
                onCommit: commitRename,
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
    }

    private var hasDoneNotes: Bool {
        store.activeNotes.contains { $0.isDone && $0.listName == name }
    }

    private func commitRename() {
        store.renameSection(from: name, to: selection.renameText)
        selection.endRenamingSection()
    }
}
