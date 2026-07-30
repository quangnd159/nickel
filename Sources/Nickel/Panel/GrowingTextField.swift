import AppKit

/// Shared font/line-spacing metrics for note display and note editing, so
/// `NoteLabel` and `InlineTextEditor` measure and wrap identically. See
/// `NoteLabel.swift` for why the two need to match pixel-for-pixel.
enum NoteTextMetrics {
    static let fontSize: CGFloat = 14
    static let lineSpacing: CGFloat = 2
}

/// An `NSTextField` whose intrinsic height grows with wrapped content (up to
/// `maximumNumberOfLines`, or unbounded when that's `0`), tracking the width
/// AppKit lays it out at via `layout()` rather than a fixed
/// `preferredMaxLayoutWidth`.
///
/// Shared by `ComposerField` (bordered-free, 5-line cap) and
/// `InlineTextEditor` (unbounded, for in-place note editing) — both need a
/// multiline field editor whose card/container grows and shrinks live as the
/// user types, which SwiftUI's own multiline `TextField` can't do under this
/// project's `@State`-free build constraint (see `PanelView.PanelUIState`).
class GrowingTextField: NSTextField {
    /// Extra spacing between wrapped lines, matching the display `Text`'s
    /// `.lineSpacing(_:)` so entering/leaving edit mode doesn't reflow height.
    /// Applied via paragraph style so both intrinsic-size measurement and the
    /// field editor's typing metrics account for it. Zero (the default) is a
    /// no-op, preserving prior behavior for fields that don't set it.
    var lineSpacing: CGFloat = 0 {
        didSet { applyParagraphStyle() }
    }

    override var stringValue: String {
        didSet { applyParagraphStyle() }
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

    /// Carries `lineSpacing` into the field editor's typing attributes so
    /// text the user types (not just what's set via `stringValue`) wraps
    /// with the same metrics as the display `Text`.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, lineSpacing > 0, let editor = currentEditor() as? NSTextView {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            editor.typingAttributes[.paragraphStyle] = style
        }
        return became
    }

    private func applyParagraphStyle() {
        guard lineSpacing > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let attributed = NSAttributedString(string: stringValue, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: style
        ])
        super.attributedStringValue = attributed
    }
}
