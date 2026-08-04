import AppKit
import SwiftUI

/// The text surface of a note's standalone editing window: a scrollable
/// `NSTextView` over the note's Markdown source.
///
/// Backed by `NSViewRepresentable` rather than SwiftUI's `TextEditor` for two
/// reasons. A document window needs real text-container insets, and neither
/// `.contentMargins(for: .scrollContent)` nor `.safeAreaPadding` reaches a
/// `TextEditor` — its text sits jammed against the window edge. And
/// `TextEditor` leaves AppKit's automatic quote/dash substitution on, which
/// silently rewrites Markdown source (`"` → `"`, `--` → –) as it's typed.
struct NoteSourceTextView: NSViewRepresentable {
    @Binding var text: String
    /// Mirrors the text view's first-responder state (SwiftUI's `@FocusState`
    /// doesn't reach into an `NSViewRepresentable`), so the editor around it
    /// can tell whether the user is typing here — see
    /// `NoteEditorView.adoptExternalEdit`.
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> NSScrollView {
        // Assembled by hand rather than via `NSTextView.scrollableTextView()`,
        // which builds a plain `NSTextView` and gives no way to substitute the
        // focus-reporting subclass below.
        let textView = FocusReportingTextView()
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = text
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.isFocused.wrappedValue = focused
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.isFocused = $isFocused
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// An `NSTextView` that reports first-responder changes, the way
/// `GrowingTextField` does for the composer. Unlike an `NSTextField`, a text
/// view *is* its own editor, so both hooks land on it directly.
private final class FocusReportingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onFocusChange?(true) }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign { onFocusChange?(false) }
        return didResign
    }
}
