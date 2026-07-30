import SwiftUI
import AppKit

/// A borderless, single-line `NSTextField` used for the panel's search box.
///
/// Backed by `NSViewRepresentable` (like `InlineTextEditor`) rather than
/// SwiftUI's `TextField` bound to `@State`/`@FocusState`, both because
/// `@State`-family macros aren't available in this build (see
/// `PanelUIState` in `PanelView.swift`) and because Esc here needs
/// context-sensitive behavior (clear text vs. give up focus) that requires
/// intercepting `cancelOperation` directly.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Search"
    /// Called when Esc is pressed while this field has focus. The caller
    /// decides what "Esc" means based on the current text (clear vs. blur).
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 13)
            ]
        )
        field.stringValue = text
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEscape: onEscape)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        var onEscape: () -> Void

        init(text: Binding<String>, onEscape: @escaping () -> Void) {
            self.text = text
            self.onEscape = onEscape
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape()
                return true
            }
            return false
        }
    }
}
