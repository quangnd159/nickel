import SwiftUI
import AppKit

/// A borderless, single-line `NSTextField` used to rename a section header
/// in place (Finder "New Folder" / rename pattern). Focused immediately with
/// all text selected. Enter commits, Esc cancels (reverting to the original
/// name), and losing first responder for any other reason (click elsewhere)
/// also commits — matching `InlineTextEditor`'s behavior for note editing.
///
/// Backed by `NSViewRepresentable` rather than SwiftUI's `TextField` bound to
/// `@State`/`@FocusState`, for the same reason as `SearchField` and
/// `InlineTextEditor`: the `@State` macro family isn't available under
/// `swift build` without Xcode.app, and this needs precise control over the
/// Enter/Esc key commands plus explicit select-all-on-focus.
struct HeaderRenameField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.stringValue = text
        field.lineBreakMode = .byTruncatingTail

        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            if field.currentEditor() != nil {
                field.currentEditor()?.selectAll(nil)
            } else {
                // The field can be created mid-layout-pass (e.g. inside a
                // ScrollView's LazyVStack), in which case `makeFirstResponder`
                // above can silently no-op. Retry once on the next runloop
                // tick, by which point layout has settled.
                DispatchQueue.main.async {
                    field.window?.makeFirstResponder(field)
                    field.currentEditor()?.selectAll(nil)
                }
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        private let onCommit: () -> Void
        private let onCancel: () -> Void
        private var didFinish = false

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finish(commit: true)
                control.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(commit: false)
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        /// Fires when the field resigns first responder for any reason,
        /// including our own explicit resignation above and clicking
        /// elsewhere in the panel; `didFinish` guards against double-commit.
        func controlTextDidEndEditing(_ notification: Notification) {
            finish(commit: true)
        }

        private func finish(commit: Bool) {
            guard !didFinish else { return }
            didFinish = true
            if commit {
                onCommit()
            } else {
                onCancel()
            }
        }
    }
}
