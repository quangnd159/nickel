import SwiftUI

/// A line-level Markdown block: the constructs `AttributedString(markdown:)`
/// in `.inlineOnlyPreservingWhitespace` mode doesn't know about (headings,
/// lists, blockquotes, code fences). Inline styling within a block's text
/// (bold/italic/links/inline code) is still handled by that inline parser.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case numbered(indent: Int, index: Int, text: String)
    case blockquote(text: String)
    case code(lines: [String])
    case paragraph(text: String)
    case blank

    /// The block's own text with its marker stripped, for a plain flattened
    /// preview (used by `NoteRow`'s collapsed 3-line clamp).
    var plainText: String {
        switch self {
        case .heading(_, let text), .bullet(_, let text), .blockquote(let text), .paragraph(let text):
            return text
        case .numbered(_, _, let text):
            return text
        case .code(let lines):
            return lines.joined(separator: " ")
        case .blank:
            return ""
        }
    }

    /// Splits `source` into blocks line by line. Deliberately simple (no
    /// nested blockquotes, no lazy paragraph continuation) since notes are
    /// short, modest snippets rather than full documents.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var codeLines: [String]?

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let leadingSpaces = line.prefix { $0 == " " }.count
            let trimmed = line.drop { $0 == " " }

            if trimmed.hasPrefix("```") {
                if let pending = codeLines {
                    blocks.append(.code(lines: pending))
                    codeLines = nil
                } else {
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(line)
                continue
            }

            if trimmed.isEmpty {
                blocks.append(.blank)
            } else if let heading = parseHeading(trimmed) {
                blocks.append(heading)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                blocks.append(.bullet(indent: leadingSpaces / 2, text: String(trimmed.dropFirst(2))))
            } else if let numbered = parseNumbered(trimmed, indent: leadingSpaces / 2) {
                blocks.append(numbered)
            } else if trimmed.hasPrefix("> ") {
                blocks.append(.blockquote(text: String(trimmed.dropFirst(2))))
            } else if trimmed == ">" {
                blocks.append(.blockquote(text: ""))
            } else {
                blocks.append(.paragraph(text: line))
            }
        }
        if let codeLines {
            blocks.append(.code(lines: codeLines))
        }
        return blocks
    }

    private static func parseHeading(_ trimmed: Substring) -> MarkdownBlock? {
        var level = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == "#", level < 6 {
            level += 1
            index = trimmed.index(after: index)
        }
        guard level > 0, index < trimmed.endIndex, trimmed[index] == " " else { return nil }
        return .heading(level: level, text: String(trimmed[trimmed.index(after: index)...]))
    }

    private static func parseNumbered(_ trimmed: Substring, indent: Int) -> MarkdownBlock? {
        var index = trimmed.startIndex
        var digits = ""
        while index < trimmed.endIndex, trimmed[index].isNumber {
            digits.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        guard !digits.isEmpty, index < trimmed.endIndex, trimmed[index] == ".", let number = Int(digits) else {
            return nil
        }
        index = trimmed.index(after: index)
        guard index < trimmed.endIndex, trimmed[index] == " " else { return nil }
        return .numbered(indent: indent, index: number, text: String(trimmed[trimmed.index(after: index)...]))
    }
}

/// Renders a note's Markdown source as block-styled SwiftUI views: headings
/// get bigger/bolder text, list items get a bullet/number gutter, blockquotes
/// get a rule and muted color, code blocks get a monospaced font. Inline
/// styling within each block goes through `AttributedString(markdown:)`.
struct MarkdownBlocksView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: headingSize(level), weight: .semibold))

        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(text)).lineSpacing(2)
            }
            .font(.system(size: 14))
            .padding(.leading, CGFloat(indent) * 14)

        case .numbered(let indent, let index, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(index).")
                Text(inline(text)).lineSpacing(2)
            }
            .font(.system(size: 14))
            .padding(.leading, CGFloat(indent) * 14)

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(.tertiary).frame(width: 2)
                Text(inline(text)).foregroundStyle(.secondary)
            }
            .font(.system(size: 14))
            .lineSpacing(2)

        case .code(let lines):
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                )

        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 14))
                .lineSpacing(2)

        case .blank:
            EmptyView()
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19
        case 2: return 17
        default: return 15
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
