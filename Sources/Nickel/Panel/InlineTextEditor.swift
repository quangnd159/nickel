import SwiftUI
import AppKit

/// A borderless, transparent, unbounded-height `NSTextField` used for inline
/// note editing, in place of the display `Text`. Enter commits, Shift+Enter
/// inserts a newline, Esc cancels, and losing first responder for any other
/// reason (e.g. clicking elsewhere in the panel) also commits.
///
/// Built on the same `GrowingTextField` (see `GrowingTextField.swift`) as
/// `ComposerField`, so the card grows and shrinks live as the user types —
/// with `maximumNumberOfLines = 0` (unbounded) rather than the composer's
/// 5-line cap, since an editing note shouldn't clamp/truncate the way its
/// `lineLimit(3)` display text does.
///
/// Line height is pinned to `NoteTextMetrics`'s fixed value (see that type's
/// doc comment) so entering/leaving edit mode doesn't visibly reflow the
/// card. `GrowingTextField.fixedParagraphStyle` covers intrinsic-size
/// measurement and freshly-typed text, but the window's field editor doesn't
/// reliably honor a paragraph style from typing attributes for text that's
/// already present when editing begins — so `pinFixedLineHeight(in:)` also
/// stamps the style directly onto the field editor's `textStorage` right
/// after focusing.
///
/// Backed by `NSViewRepresentable` rather than SwiftUI's `TextField(axis:
/// .vertical)` bound to `@State`, since `@State` isn't available in this
/// build (see `PanelUIState` in `PanelView.swift` for why), and because this
/// needs precise control over the Enter/Esc key commands.
struct InlineTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> GrowingTextField {
        let field = GrowingTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NoteTextMetrics.fontSize)
        field.textColor = .labelColor
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.fixedParagraphStyle = NoteTextMetrics.makeParagraphStyle()
        field.stringValue = text

        focusAtEnd(field)
        return field
    }

    func updateNSView(_ nsView: GrowingTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
            nsView.invalidateIntrinsicContentSize()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    /// Places the caret at the end of the existing text (no select-all: this
    /// is an edit of existing content, not a fresh entry, so replacing
    /// everything on an accidental keystroke would be dangerous for a long
    /// note). Mirrors the one-tick retry in `HeaderRenameField`: the field
    /// can be created mid-layout-pass (e.g. inside a ScrollView's
    /// `LazyVStack`), in which case `makeFirstResponder` can silently no-op
    /// on the first attempt.
    private func focusAtEnd(_ field: NSTextField) {
        func placeCaretAtEnd() {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            Self.pinFixedLineHeight(in: editor)
            let end = (editor.string as NSString).length
            editor.selectedRange = NSRange(location: end, length: 0)
        }
        DispatchQueue.main.async {
            placeCaretAtEnd()
            if field.currentEditor() == nil {
                DispatchQueue.main.async {
                    placeCaretAtEnd()
                }
            }
        }
    }

    /// Forces the field editor to the same fixed line height as the display
    /// label and freshly-typed text: `defaultParagraphStyle` and
    /// `typingAttributes` for anything typed from here on, and the style plus
    /// base font stamped directly onto `textStorage` for the text already in
    /// the field when editing began (which typing attributes alone don't
    /// reliably cover — see this file's doc comment).
    fileprivate static func pinFixedLineHeight(in editor: NSTextView) {
        let style = NoteTextMetrics.makeParagraphStyle()
        let font = NSFont.systemFont(ofSize: NoteTextMetrics.fontSize)
        editor.defaultParagraphStyle = style
        editor.typingAttributes = [
            .paragraphStyle: style,
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        if let textStorage = editor.textStorage {
            let fullRange = NSRange(location: 0, length: textStorage.length)
            textStorage.addAttribute(.paragraphStyle, value: style, range: fullRange)
            textStorage.addAttribute(.font, value: font, range: fullRange)
        }
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

        /// Belt-and-braces alongside the `focusAtEnd` retry loop: whichever
        /// path actually lands the field editor, this re-pins the fixed line
        /// height right as editing begins.
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            InlineTextEditor.pinFixedLineHeight(in: editor)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
            field.invalidateIntrinsicContentSize()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    finish(commit: true)
                    control.window?.makeFirstResponder(nil)
                }
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
