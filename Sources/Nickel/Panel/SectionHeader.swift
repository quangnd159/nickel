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

    /// Space above the label, part of the header itself rather than added
    /// around it, so the click area covers it. As a table group row that gap
    /// is most of what the user sees of the header — the run of empty space
    /// at the end of the section above — and a click there has to land
    /// somewhere.
    var topPadding: CGFloat = 0

    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions

    private var isRenaming: Bool { selection.renamingSectionName == name }

    var body: some View {
        Group {
            if isRenaming {
                // No taps of its own while the field is up: the field takes
                // its own clicks, and a gesture wrapped around it would take
                // them first.
                header
            } else {
                // A header row is mostly the run of empty space at the end of
                // the section above it, so a click anywhere on it means
                // "nothing", the same as a click below the last note. Rename
                // stays a double-click on the label itself (below): a
                // double-click out in the empty space shouldn't open a field.
                header
                    .contentShape(Rectangle())
                    // Simultaneous, not a plain `onTapGesture`: a single click
                    // must never wait to find out whether a second one is
                    // coming. This fires on the first click wherever it lands,
                    // including on the label, and the label's own
                    // double-click still opens the rename on the second —
                    // clearing first and renaming after is the same
                    // click-then-double-click stacking Finder uses.
                    .simultaneousGesture(TapGesture().onEnded { actions.clickedNothing() })
            }
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

    private var header: some View {
        HStack(spacing: 8) {
            if isRenaming {
                renameField
            } else {
                Text(name)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { selection.beginRenamingSection(name) }
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(.isHeader)
            }

            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
        // Held at the taller of the two states — the rename box — so opening
        // a rename doesn't grow the row and push every note below it down.
        // The label just sits centred in the same space it always occupied.
        .frame(height: Self.contentHeight)
        .padding(.top, topPadding)
    }

    /// The header's height in both states: the rename box (11pt text, 2pt of
    /// padding each side, 1pt border) is the taller one, and the label is
    /// given the same room. Verified by `NICKEL_UI_PROBE=1`.
    private static let contentHeight: CGFloat = 18

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
        }
        .frame(minWidth: 60, maxWidth: 240, alignment: .leading)
        // Without this the field is merely *allowed* to be up to 240 wide, so
        // the `HStack` hands it half the row and the sizing text above never
        // gets to decide anything. Fixing the width makes the frame resolve to
        // the text's own width, clamped, which is what grows with typing.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        // Finder's rename look: the field's own white surface, outlined in the
        // accent colour to mark the keyboard focus. Quiet and static, where
        // the system bezel's focus ring is a glow that animates in.
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 1)
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
