import AppKit

/// An `NSTextField` whose intrinsic height grows with wrapped content (up to
/// `maximumNumberOfLines`, or unbounded when that's `0`), tracking the width
/// AppKit lays it out at via `layout()` rather than a fixed
/// `preferredMaxLayoutWidth`.
///
/// Used by `ComposerField` (bordered-free, 5-line cap), which needs a
/// multiline field editor whose card/container grows and shrinks live as the
/// user types.
class GrowingTextField: NSTextField {
    /// Called with `true` when the field takes focus and `false` when it
    /// gives it up, so the card around it can draw a focus ring. The two
    /// hooks aren't symmetric on purpose: a focused `NSTextField` hands first
    /// responder straight to the window's field editor, so `resignFirstResponder`
    /// is never called on the field itself and `textDidEndEditing` is the
    /// matching notification for focus loss.
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onFocusChange?(true) }
        return didBecome
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        if width > 0, preferredMaxLayoutWidth != width {
            preferredMaxLayoutWidth = width
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let cell, preferredMaxLayoutWidth > 0 else { return super.intrinsicContentSize }
        let size = cell.cellSize(forBounds: NSRect(
            x: 0, y: 0,
            width: preferredMaxLayoutWidth,
            height: .greatestFiniteMagnitude
        ))
        return NSSize(width: NSView.noIntrinsicMetric, height: size.height)
    }

    /// Re-syncs the cell's `attributedStringValue` from the field editor's
    /// live `textStorage` and invalidates intrinsic size, so the card's
    /// height tracks what's actually been typed. `intrinsicContentSize`
    /// measures via `cell.cellSize(forBounds:)`, but the cell's own
    /// `attributedStringValue` is a snapshot from whenever it was last
    /// explicitly set (e.g. `makeNSView`'s initial `stringValue = text`) — it
    /// isn't kept live by AppKit while the field editor is being typed into.
    /// Call from a delegate's `controlTextDidChange(_:)`.
    func syncIntrinsicSizeWithEditor() {
        if let editor = currentEditor() as? NSTextView, let textStorage = editor.textStorage {
            cell?.attributedStringValue = textStorage
        }
        invalidateIntrinsicContentSize()
    }
}
