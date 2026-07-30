import SwiftUI
import AppKit

/// A borderless, transparent multiline `NSTextView` used for inline note
/// editing. Enter commits, Esc cancels, and losing first responder for any
/// other reason (e.g. clicking elsewhere in the panel) also commits.
///
/// Backed by `NSViewRepresentable` rather than SwiftUI's `TextField(axis:
/// .vertical)` bound to `@State`, since `@State` isn't available in this
/// build (see `PanelUIState` in `PanelView.swift` for why), and because this
/// needs precise control over the Enter/Esc key commands.
struct InlineTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 13)
        textView.string = text
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.selectAll(nil)
        }
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        if nsView.string != text {
            nsView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let onCommit: () -> Void
        private let onCancel: () -> Void
        private var didFinish = false

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finish(commit: true)
                textView.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(commit: false)
                textView.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        /// Fires when the text view resigns first responder for any reason,
        /// including our own explicit resignation above and clicking
        /// elsewhere in the panel; `didFinish` guards against double-commit.
        func textDidEndEditing(_ notification: Notification) {
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
