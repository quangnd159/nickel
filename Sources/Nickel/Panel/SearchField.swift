import SwiftUI
import AppKit

/// Posted by `FloatingPanel` when ⌘F is pressed, so `SearchField` can focus
/// its field editor even though the panel deliberately opens with no first
/// responder (see `FloatingPanel.animateShow`).
extension Notification.Name {
    static let nickelFocusSearch = Notification.Name("NickelFocusSearch")
}

/// A borderless, single-line `NSTextField` used for the panel's search box.
///
/// Backed by `NSViewRepresentable` rather than SwiftUI's `TextField`: Esc
/// here needs context-sensitive behavior (clear text vs. give up focus) that
/// requires intercepting `cancelOperation` directly.
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
        context.coordinator.field = field
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
        weak var field: NSTextField?

        init(text: Binding<String>, onEscape: @escaping () -> Void) {
            self.text = text
            self.onEscape = onEscape
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(focusSearch),
                name: .nickelFocusSearch,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func focusSearch() {
            guard let field else { return }
            field.window?.makeFirstResponder(field)
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
