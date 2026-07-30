import SwiftUI
import AppKit

/// A single note card: circle checkbox + note text (or an inline editor),
/// styled to match the Copper-style panel (white/dark-gray rounded card,
/// blue selection outline). Handles click-to-select (with ⌘/⇧ modifiers),
/// double-click-to-edit, and the note's context menu.
///
/// Display and edit both run through SwiftUI's own text engine (`Text` and
/// `TextField(axis: .vertical)`) at the same 14pt/`.lineSpacing(2)` metrics,
/// so wrapping and height match by construction.
struct NoteRow: View {
    let note: Note
    let onToggleDone: () -> Void

    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions
    @FocusState private var editFocus: Bool

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
                    editField
                } else {
                    displayText
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

    // MARK: - Editing / display subviews
    //
    // Split out of `body` (rather than inlined into its `Group`) because the
    // combined modifier chain otherwise took the type-checker too long to
    // solve ("the compiler is unable to type-check this expression in
    // reasonable time"); each computed property type-checks independently.

    private var editingTextBinding: Binding<String> {
        Binding(
            get: { selection.editingText },
            set: { selection.editingText = $0 }
        )
    }

    private var editField: some View {
        TextField("", text: editingTextBinding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineSpacing(2)
            .lineLimit(1...)
            .focused($editFocus)
            .onAppear(perform: focusEditField)
            .onChange(of: isEditing, focusEditFieldIfNowEditing)
            .onChange(of: editFocus, commitOnFocusLoss)
            .onKeyPress(.return, phases: .down) { (press: KeyPress) in handleReturnKeyPress(press) }
            .onKeyPress(.escape) { handleEscapeKeyPress() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayText: some View {
        Text(renderedText)
            .font(.system(size: 14))
            .lineSpacing(2)
            .foregroundStyle(.primary)
            .lineLimit(selection.expandedIDs.contains(note.id) ? nil : 3)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(note.isDone ? 0.5 : 1)
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
        // Clicking another row while this one is mid-edit steals focus,
        // which fires `editFocus`'s `onChange` and commits — but that's a
        // separate view instance's state, so it can lose a race against the
        // selection mutation below if both land in the same tick. Committing
        // explicitly here first guarantees the previously-edited note's text
        // is saved before selection moves on.
        actions.commitActiveEditIfAny()
        guard !isEditing else { return }
        let flags = NSEvent.modifierFlags
        selection.handleClick(on: note.id, shift: flags.contains(.shift), command: flags.contains(.command))
    }

    private func handleDoubleClick(at location: CGPoint) {
        guard !isInCheckboxColumn(location) else { return }
        actions.commitActiveEditIfAny()
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
        guard isEditing else { return }
        store.update(id: note.id, text: selection.editingText)
        selection.endEditing()
    }

    // MARK: - Inline edit field focus/keys
    //
    // Broken out into named methods (rather than inline closures on the
    // `TextField` modifier chain) because the chain otherwise took the
    // type-checker too long to solve, per "the compiler is unable to
    // type-check this expression in reasonable time".

    private func focusEditField() {
        editFocus = true
    }

    private func focusEditFieldIfNowEditing(_ old: Bool, _ editing: Bool) {
        if editing { editFocus = true }
    }

    /// Click-away commit: fires whenever the field's focus changes, which
    /// covers losing focus to another control (search field, composer,
    /// background click) as well as another `NoteRow` stealing focus when
    /// its own edit begins.
    private func commitOnFocusLoss(_ old: Bool, _ focused: Bool) {
        guard !focused, isEditing else { return }
        commitEdit()
    }

    /// `TextField(axis: .vertical)` inserts a newline for plain Return by
    /// default (it only calls `onSubmit` for single-line fields), so Shift
    /// is not actually needed to get a newline here — but we still want
    /// plain Return to commit. Returning `.ignored` for Shift+Return lets
    /// the field's default newline insertion run; returning `.handled` for
    /// plain Return swallows the keystroke (no newline inserted) and commits
    /// instead.
    private func handleReturnKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.shift) {
            return .ignored
        }
        commitEdit()
        return .handled
    }

    private func handleEscapeKeyPress() -> KeyPress.Result {
        selection.endEditing()
        return .handled
    }

    /// Builds the display string via inline markdown parsing
    /// (`AttributedString(markdown:, options:
    /// .inlineOnlyPreservingWhitespace)`), with a plain-text fallback for
    /// unparseable input.
    private var renderedText: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: note.text, options: options)) ?? AttributedString(note.text)
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
