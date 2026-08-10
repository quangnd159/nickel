import AppKit

/// An `NSTextField` whose intrinsic height grows with wrapped content (up to
/// `maximumNumberOfLines`, or unbounded when that's `0`), tracking the width
/// AppKit lays it out at via `layout()` rather than a fixed
/// `preferredMaxLayoutWidth`.
///
/// Used by `ComposerField` (bordered-free, 5-line cap), which needs a
/// multiline field editor whose card/container grows and shrinks live as the
/// user types.
/// The composer's focus state is deliberately *not* tracked here: this field
/// can only see focus loss that comes from editing ending, which misses the
/// panel simply stopping being the key window. `FloatingPanel` watches its own
/// first responder and key state instead (see `SelectionModel.isComposerFocused`).
class GrowingTextField: NSTextField {
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
        let cellHeight = cell.cellSize(forBounds: NSRect(
            x: 0, y: 0,
            width: preferredMaxLayoutWidth,
            height: .greatestFiniteMagnitude
        )).height
        // `cellSize(forBounds:)` wraps against the cell's title rect, which
        // is inset a few points narrower than the field itself, so wrapped
        // text routinely measures a phantom line taller than it actually
        // renders (68pt for a 3-line string that lays out at 51pt) — the
        // extra height showed up as blank space under the last line.
        // `boundingRect` at the real wrap width matches what's rendered.
        // `cellSize` remains as the cap — it's what honors
        // `maximumNumberOfLines` — and as the empty-string height (a
        // zero-height measurement would collapse the field entirely).
        guard attributedStringValue.length > 0 else {
            return NSSize(width: NSView.noIntrinsicMetric, height: cellHeight)
        }
        let textHeight = attributedStringValue.boundingRect(
            with: NSSize(width: preferredMaxLayoutWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).height
        return NSSize(width: NSView.noIntrinsicMetric, height: min(ceil(textHeight), cellHeight))
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
