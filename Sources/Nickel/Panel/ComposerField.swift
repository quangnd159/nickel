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
/// panel's composer ("Add a note or a prompt"), built on the shared
/// `GrowingTextField` (see `GrowingTextField.swift`).
///
/// Backed by `NSViewRepresentable` rather than SwiftUI's
/// `TextField(axis: .vertical)`: Return here needs context-sensitive
/// behavior (commit-and-keep-focus on plain Return vs. insert-a-line-break
/// on Shift+Return) that requires intercepting `insertNewline` directly, and
/// the field needs to auto-grow to fit its content inside the composer's
/// card.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    /// Mirrors the field's first-responder state, so the composer card
    /// around it can draw a focus ring (SwiftUI's `@FocusState` doesn't reach
    /// into an `NSViewRepresentable`).
    @Binding var isFocused: Bool
    var placeholder: String = "Add a note or a prompt"
    /// Called when plain Return is pressed. The caller adds the note and
    /// clears the text; focus is deliberately kept so the next note can be
    /// typed immediately.
    var onCommit: () -> Void

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
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.isFocused.wrappedValue = focused
        }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ nsView: GrowingTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
            nsView.invalidateIntrinsicContentSize()
        }
        context.coordinator.onCommit = onCommit
        context.coordinator.isFocused = $isFocused
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onCommit: onCommit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        var isFocused: Binding<Bool>
        var onCommit: () -> Void
        weak var field: NSTextField?

        init(text: Binding<String>, isFocused: Binding<Bool>, onCommit: @escaping () -> Void) {
            self.text = text
            self.isFocused = isFocused
            self.onCommit = onCommit
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
                } else {
                    onCommit()
                }
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}
