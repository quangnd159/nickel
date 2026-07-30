import AppKit

/// Shared font/line-height metrics for note display and note editing, so
/// `NoteLabel` and `InlineTextEditor` measure and wrap identically. See
/// `NoteLabel.swift` for why the two need to match pixel-for-pixel.
///
/// Line height is pinned to an absolute value (`minimumLineHeight ==
/// maximumLineHeight == lineHeight`, `lineSpacing = 0`) rather than expressed
/// as `lineSpacing` on top of the font's natural line height: the window's
/// field editor (the `NSTextView` AppKit substitutes in while an `NSTextField`
/// is being edited) doesn't reliably honor `paragraphStyle.lineSpacing` from
/// typing attributes for text that's already in the field when editing
/// begins, which let edit-mode line height drift slightly from display mode.
/// An absolute min/max line height is enforced by the layout manager
/// regardless of that path, so it stays identical everywhere.
enum NoteTextMetrics {
    static let fontSize: CGFloat = 14
    static let lineHeight: CGFloat = 20

    static func makeParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineSpacing = 0
        return style
    }
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
    /// A fixed paragraph style (see `NoteTextMetrics.makeParagraphStyle()`)
    /// matching the display label's, so entering/leaving edit mode doesn't
    /// reflow height. Applied via `attributedStringValue` so intrinsic-size
    /// measurement accounts for it; `nil` (the default) is a no-op,
    /// preserving prior behavior for fields that don't set it.
    var fixedParagraphStyle: NSParagraphStyle? {
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

    /// Carries `fixedParagraphStyle` into the field editor's typing
    /// attributes so text the user types (not just what's set via
    /// `stringValue`) wraps with the same metrics as the display label. This
    /// alone isn't sufficient for text that's already in the field when
    /// editing begins (see `InlineTextEditor`, which pins the field editor's
    /// `textStorage` directly for that case); it's kept here mainly so
    /// intrinsic-size measurement and freshly-typed text agree.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let style = fixedParagraphStyle, let editor = currentEditor() as? NSTextView {
            editor.typingAttributes[.paragraphStyle] = style
        }
        return became
    }

    private func applyParagraphStyle() {
        guard let style = fixedParagraphStyle else { return }
        let attributed = NSAttributedString(string: stringValue, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: style
        ])
        super.attributedStringValue = attributed
    }
}
