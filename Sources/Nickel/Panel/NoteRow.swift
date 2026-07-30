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
                    .font(.system(size: 14))
                    .frame(minHeight: 18)
                } else {
                    Text(renderedText)
                        .font(.system(size: 14))
                        .lineSpacing(2)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .truncationMode(.tail)
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
        // padding) selects it. Plain (non-simultaneous) `onTapGesture`s here
        // are exclusive gestures, so the checkbox `Button` — a child control
        // with its own tap handling — wins hits on itself and this row-level
        // gesture never fires for it; that keeps the checkbox selection-inert
        // (a pure work-tracking control, Copper/Reminders/Things-style)
        // without needing to scope the gesture to the text column only.
        // `count: 2` is attached before `count: 1` so both fire independently
        // with no double-click wait delaying the single-click response.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { handleDoubleClick() }
        .onTapGesture { handleSingleClick() }
        .contextMenu { contextMenuContent }
    }

    // MARK: - Click handling

    private func handleSingleClick() {
        guard !isEditing else { return }
        let flags = NSEvent.modifierFlags
        selection.handleClick(on: note.id, shift: flags.contains(.shift), command: flags.contains(.command))
    }

    private func handleDoubleClick() {
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

    private var renderedText: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: note.text, options: options)) ?? AttributedString(note.text)
    }
}
