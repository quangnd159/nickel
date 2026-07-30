import SwiftUI
import AppKit

/// A single note card: circle checkbox + note text (or an inline editor),
/// styled to match the Copper-style panel (white/dark-gray rounded card,
/// blue selection outline). Handles click-to-select (with ⌘/⇧ modifiers),
/// double-click-to-edit, and the note's context menu.
struct NoteRow: View {
    let note: Note
    let onToggleDone: () -> Void

    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions

    private var isSelected: Bool { selection.selectedIDs.contains(note.id) }
    private var isEditing: Bool { selection.editingID == note.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggleDone) {
                Image(systemName: note.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(note.isDone ? .secondary : .quaternary)
                    .frame(height: 19)
            }
            .buttonStyle(.plain)

            Group {
                if isEditing {
                    InlineTextEditor(
                        text: Binding(
                            get: { selection.editingText },
                            set: { selection.editingText = $0 }
                        ),
                        onCommit: commitEdit,
                        onCancel: { selection.endEditing() }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    NoteLabel(
                        text: note.text,
                        maximumNumberOfLines: selection.expandedIDs.contains(note.id) ? 0 : 3
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(note.isDone ? 0.5 : 1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        )
        .background(RightClickPreSelector { actions.selectOnRightClick(note.id) })
        // Row-wide click target: clicking anywhere on the card (including its
        // padding) selects it. `simultaneousGesture` (rather than a plain,
        // exclusive `onTapGesture`) makes the single-click recognizer fire
        // immediately on mouse-up instead of waiting out the double-click
        // window for the count:2 recognizer to fail — that wait is what made
        // click-to-select feel slow. Because simultaneous gestures don't
        // exclude the checkbox `Button`'s own tap handling, both handlers
        // explicitly ignore hits that land in the checkbox column (see
        // `isInCheckboxColumn`) so the checkbox stays selection-inert (a pure
        // work-tracking control, Copper/Reminders/Things-style).
        .contentShape(Rectangle())
        .simultaneousGesture(
            SpatialTapGesture(count: 1).onEnded { value in handleSingleClick(at: value.location) }
        )
        .simultaneousGesture(
            SpatialTapGesture(count: 2).onEnded { value in handleDoubleClick(at: value.location) }
        )
        .contextMenu { contextMenuContent }
    }

    // MARK: - Click handling

    // Card horizontal padding (14) + checkbox glyph width (19) + half the
    // HStack's 12pt gap (6) = 39: taps left of this x fall on the checkbox
    // and belong to its own Button, not row selection.
    private let checkboxColumnMaxX: CGFloat = 14 + 19 + 12 / 2

    private func isInCheckboxColumn(_ location: CGPoint) -> Bool {
        location.x < checkboxColumnMaxX
    }

    private func handleSingleClick(at location: CGPoint) {
        guard !isInCheckboxColumn(location) else { return }
        guard !isEditing else { return }
        let flags = NSEvent.modifierFlags
        selection.handleClick(on: note.id, shift: flags.contains(.shift), command: flags.contains(.command))
    }

    private func handleDoubleClick(at location: CGPoint) {
        guard !isInCheckboxColumn(location) else { return }
        guard !isEditing else { return }
        let flags = NSEvent.modifierFlags
        guard !flags.contains(.command), !flags.contains(.shift) else { return }
        beginEditing()
    }

    private func beginEditing() {
        selection.selectSingle(note.id)
        selection.beginEditing(id: note.id, text: note.text)
    }

    private func commitEdit() {
        store.update(id: note.id, text: selection.editingText)
        selection.endEditing()
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("Copy") { actions.copy() }
            .keyboardShortcut("c", modifiers: .command)

        Button("Copy as List") { actions.copyAsList() }
            .keyboardShortcut("c", modifiers: [.command, .shift])

        Divider()

        Button(actions.allSelectedAreDone ? "Mark as Not Done" : "Mark as Done") {
            actions.toggleDone()
        }
        .keyboardShortcut(" ", modifiers: [])

        Button(actions.allSelectedAreExpanded ? "Collapse" : "Expand") {
            actions.toggleExpanded()
        }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(selection.selectedIDs.isEmpty)

        Button("Edit") { actions.startEditingIfSingleSelected() }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(selection.selectedIDs.count != 1)

        Button("Merge Notes") { actions.merge() }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(selection.selectedIDs.count < 2)

        Menu("Move to") {
            ForEach(store.listNames, id: \.self) { listName in
                Button(listName) { actions.move(toList: listName) }
            }
            Button("No List") { actions.move(toList: nil) }
            Divider()
            Button("New List…") { actions.createListWithSelection() }
        }

        Divider()

        Button("Delete") { actions.delete() }
            .keyboardShortcut(.delete, modifiers: [])
    }
}
