import SwiftUI
import AppKit

/// A non-interactive, 3-line-truncated note display built on the same
/// `GrowingTextField` (see `GrowingTextField.swift`) that backs
/// `InlineTextEditor`, so display and edit modes share one layout engine.
///
/// Previously `NoteRow` rendered display text with a SwiftUI `Text`, which
/// measures and wraps independently of the `NSTextField`-based editor. The
/// two engines round line heights slightly differently, so the card shifted
/// ~1-2pt when entering/leaving edit mode. Using the same `GrowingTextField`
/// subclass (same font, same `NSParagraphStyle` line spacing, same
/// `preferredMaxLayoutWidth`-from-`layout()` growth mechanism) for both means
/// identical wrap points and identical intrinsic height at the same width.
struct NoteLabel: NSViewRepresentable {
    var text: String
    var maximumNumberOfLines: Int = 3

    func makeNSView(context: Context) -> NoteLabelField {
        let field = NoteLabelField()
        field.isEditable = false
        field.isSelectable = false
        field.refusesFirstResponder = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.cell?.truncatesLastVisibleLine = true
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = maximumNumberOfLines
        field.attributedStringValue = NoteLabel.attributedString(from: text)
        return field
    }

    func updateNSView(_ nsView: NoteLabelField, context: Context) {
        nsView.maximumNumberOfLines = maximumNumberOfLines
        let attributed = NoteLabel.attributedString(from: text)
        if nsView.attributedStringValue != attributed {
            nsView.attributedStringValue = attributed
            nsView.invalidateIntrinsicContentSize()
        }
    }

    /// Shared paragraph style, identical to the one `InlineTextEditor` (via
    /// `GrowingTextField.lineSpacing`) carries into its typing attributes.
    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = NoteTextMetrics.lineSpacing
        return style
    }()

    private static let baseFont = NSFont.systemFont(ofSize: NoteTextMetrics.fontSize)

    /// Builds the display string by parsing the same inline markdown
    /// `NoteRow`'s old `Text`-based rendering used
    /// (`AttributedString(markdown:, options: .inlineOnlyPreservingWhitespace)`),
    /// then walking its runs directly rather than round-tripping through
    /// `NSAttributedString(attrString)` first: `AttributedString`'s
    /// `inlinePresentationIntent` per run is the authoritative signal for
    /// bold/italic, and reading it straight off the parsed runs avoids
    /// depending on whether the automatic Foundation -> AppKit attribute
    /// bridge happens to translate that intent into a trait-adjusted font.
    /// Every run gets the shared paragraph style and `labelColor`; the base
    /// 14pt system font is used unless the run's intent calls for bold and/or
    /// italic, in which case the corresponding 14pt system font variant
    /// (via `NSFontManager` symbolic traits) is substituted.
    static func attributedString(from text: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let substring = String(parsed[run.range].characters)
            var font = baseFont
            if let intent = run.inlinePresentationIntent {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
                    font = NSFont(descriptor: descriptor, size: NoteTextMetrics.fontSize) ?? baseFont
                }
            }
            result.append(NSAttributedString(string: substring, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]))
        }
        return result
    }
}

/// Passes every hit through to the row underneath: the label is purely
/// decorative, and click-to-select / double-click-to-edit are handled by
/// `NoteRow`'s own gestures on the row as a whole.
final class NoteLabelField: GrowingTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
