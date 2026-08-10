import SwiftUI
import AppKit

/// Posted by `FloatingPanel` when ⌘N is pressed, so `ComposerField` can focus
/// its field editor even though the panel deliberately opens with no first
/// responder (see `FloatingPanel.animateShow`). Mirrors `.nickelFocusSearch`
/// in `SearchField.swift`.
extension Notification.Name {
    static let nickelFocusComposer = Notification.Name("NickelFocusComposer")
}

/// A borderless, multiline (up to 5 lines) `NSTextField` used for the
/// panel's composer ("Add a note"), built on the shared
/// `GrowingTextField` (see `GrowingTextField.swift`).
///
/// Backed by `NSViewRepresentable` rather than SwiftUI's
/// `TextField(axis: .vertical)`: Return here needs context-sensitive
/// behavior (commit-and-keep-focus on plain Return, insert-a-line-break on
/// Shift+Return, accept the highlighted row while the "#" section-suggestion
/// popup is open) that requires intercepting `insertNewline` directly, and
/// the field needs to auto-grow to fit its content inside the composer's
/// card. ↑/↓/Tab/Esc are intercepted for the same popup, which never takes
/// first responder — the field keeps focus throughout.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Add a note"
    /// Called when plain Return is pressed. The caller adds the note and
    /// clears the text; focus is deliberately kept so the next note can be
    /// typed immediately.
    var onCommit: () -> Void
    /// Called when ⌫ is pressed with the caret at the very start of the
    /// field and no selection. Returns whether it was handled (e.g. a
    /// staged section chip was removed); if `false`, the field falls
    /// through to its normal backspace behavior (a no-op at the start of
    /// the text anyway). Defaults to "never handled" so callers that don't
    /// need this (none currently) can ignore it.
    var onDeleteBackwardAtStart: () -> Bool = { false }
    /// Called on ↓ (`+1`) and ↑ (`-1`). Returns whether it was handled — i.e.
    /// whether the "#" suggestion popup is open and moved its highlight. When
    /// `false`, the arrow keeps its normal caret-moving behavior.
    var onMoveHighlight: (Int) -> Bool = { _ in false }
    /// Called on Return and Tab: accepts the popup's highlighted row, if the
    /// popup is open. Returns whether it was handled; on `false`, Return
    /// falls through to `onCommit` and Tab to its normal behavior.
    var onAcceptSuggestion: () -> Bool = { false }
    /// Called on Esc. Returns whether it was handled (the popup was open and
    /// is now dismissed); on `false`, Esc keeps its existing meaning of
    /// giving up focus.
    var onEscape: () -> Bool = { false }

    func makeNSView(context: Context) -> GrowingTextField {
        let field = GrowingTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 5
        field.lineBreakMode = .byWordWrapping
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 14)
            ]
        )
        field.stringValue = text
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ nsView: GrowingTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
            nsView.invalidateIntrinsicContentSize()
        }
        context.coordinator.onCommit = onCommit
        context.coordinator.onDeleteBackwardAtStart = onDeleteBackwardAtStart
        context.coordinator.onMoveHighlight = onMoveHighlight
        context.coordinator.onAcceptSuggestion = onAcceptSuggestion
        context.coordinator.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(
            text: $text,
            onCommit: onCommit,
            onDeleteBackwardAtStart: onDeleteBackwardAtStart
        )
        coordinator.onMoveHighlight = onMoveHighlight
        coordinator.onAcceptSuggestion = onAcceptSuggestion
        coordinator.onEscape = onEscape
        return coordinator
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        var onCommit: () -> Void
        var onDeleteBackwardAtStart: () -> Bool
        var onMoveHighlight: (Int) -> Bool = { _ in false }
        var onAcceptSuggestion: () -> Bool = { false }
        var onEscape: () -> Bool = { false }
        weak var field: NSTextField?

        init(text: Binding<String>, onCommit: @escaping () -> Void, onDeleteBackwardAtStart: @escaping () -> Bool) {
            self.text = text
            self.onCommit = onCommit
            self.onDeleteBackwardAtStart = onDeleteBackwardAtStart
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(focusComposer),
                name: .nickelFocusComposer,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func focusComposer() {
            guard let field else { return }
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.moveToEndOfDocument(nil)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? GrowingTextField else { return }
            text.wrappedValue = field.stringValue
            field.syncIntrinsicSizeWithEditor()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else if !onAcceptSuggestion() {
                    onCommit()
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return onAcceptSuggestion()
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                return onMoveHighlight(1)
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                return onMoveHighlight(-1)
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if onEscape() { return true }
                control.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                let range = textView.selectedRange()
                if range.location == 0, range.length == 0, onDeleteBackwardAtStart() {
                    return true
                }
                return false
            }
            return false
        }
    }
}
