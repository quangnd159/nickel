import AppKit

/// Converts rich pasteboard content (HTML or RTF) to Markdown so captured
/// selections keep their formatting. Both flavors are parsed down to an
/// `NSAttributedString` (via AppKit's built-in importers) and then walked
/// paragraph by paragraph, emitting Markdown for the constructs Copper
/// supports: bold, italic, links, inline code, headings, bullet/numbered
/// lists, code blocks, and blockquotes.
///
/// Deliberately conservative: a run only gets Markdown markers when its
/// attributes actually say so (bold trait, link, monospaced font, list
/// paragraph style, indentation). Plain runs are emitted verbatim, with no
/// escaping of incidental `*`/`_`/backtick characters, so ordinary
/// plain-looking text survives round-trip unchanged.
enum MarkdownConverter {
    static func markdown(fromHTML data: Data) -> String? {
        // AppKit's HTML importer must run on the main thread (it synchronizes
        // with it internally and times out when called from elsewhere), but
        // capture runs on a background queue — hop over if needed.
        let parse = { NSAttributedString(html: data, documentAttributes: nil) }
        let attributed = Thread.isMainThread ? parse() : DispatchQueue.main.sync(execute: parse)
        guard let attributed else { return nil }
        return markdown(from: attributed)
    }

    static func markdown(fromRTF data: Data) -> String? {
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { return nil }
        return markdown(from: attributed)
    }

    // MARK: - Paragraph walk

    private static func markdown(from attributed: NSAttributedString) -> String {
        let string = attributed.string as NSString
        guard string.length > 0 else { return "" }

        // Each block carries whether it's a list item, so consecutive items
        // of the same list can be joined tightly (single newline) instead of
        // getting a blank line between every bullet.
        var blocks: [(text: String, isListItem: Bool)] = []
        var codeBlockLines: [String] = []
        var listCounters: [ObjectIdentifier: Int] = [:]

        func flushCodeBlock() {
            guard !codeBlockLines.isEmpty else { return }
            blocks.append((text: (["```"] + codeBlockLines + ["```"]).joined(separator: "\n"), isListItem: false))
            codeBlockLines = []
        }

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, paragraphRange, _, _ in
            guard paragraphRange.length > 0 else {
                flushCodeBlock()
                return
            }

            let paragraphStyle = attributed.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle
            let font = attributed.attribute(.font, at: paragraphRange.location, effectiveRange: nil) as? NSFont

            if isMonospaced(font), (paragraphStyle?.textLists.isEmpty ?? true) {
                codeBlockLines.append(attributed.attributedSubstring(from: paragraphRange).string)
                return
            }
            flushCodeBlock()

            if let textLists = paragraphStyle?.textLists, let list = textLists.last {
                // AppKit's HTML importer bakes the visible marker into the
                // text itself as "\t<marker>\t<content>"; skip past it so it
                // isn't duplicated alongside the Markdown marker we emit.
                let contentRange = rangeAfterListMarker(in: paragraphRange, string: string)
                let inline = inlineMarkdown(for: contentRange, in: attributed)
                let indent = String(repeating: "  ", count: max(0, textLists.count - 1))
                if list.markerFormat == .disc || list.markerFormat == .circle || list.markerFormat == .hyphen || list.markerFormat == .box || list.markerFormat == .check {
                    blocks.append((indent + "- " + inline, true))
                } else {
                    let key = ObjectIdentifier(list)
                    let count = (listCounters[key] ?? list.startingItemNumber - 1) + 1
                    listCounters[key] = count
                    blocks.append((indent + "\(count). " + inline, true))
                }
                return
            }

            if let level = headingLevel(for: font) {
                let inline = inlineMarkdown(for: paragraphRange, in: attributed, suppressBold: true)
                blocks.append((String(repeating: "#", count: level) + " " + inline, false))
                return
            }

            let inline = inlineMarkdown(for: paragraphRange, in: attributed)

            if (paragraphStyle?.headIndent ?? 0) > 0 {
                blocks.append(("> " + inline, false))
                return
            }

            blocks.append((inline, false))
        }
        flushCodeBlock()

        // Join with a blank line between blocks, except consecutive list
        // items of the same list, which join with a single newline.
        var result = ""
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result += (block.isListItem && blocks[index - 1].isListItem) ? "\n" : "\n\n"
            }
            result += block.text
        }
        return result
    }

    // MARK: - Inline runs

    /// Finds the content range within a list-item paragraph, skipping the
    /// leading "\t<marker>\t" AppKit's HTML importer bakes into the text.
    /// Falls back to the whole paragraph if that shape isn't found.
    private static func rangeAfterListMarker(in paragraphRange: NSRange, string: NSString) -> NSRange {
        let searchLimit = min(paragraphRange.length, 8)
        let head = string.substring(with: NSRange(location: paragraphRange.location, length: searchLimit))
        guard let firstTab = head.firstIndex(of: "\t"),
              let secondTab = head[head.index(after: firstTab)...].firstIndex(of: "\t") else {
            return paragraphRange
        }
        let skip = head.distance(from: head.startIndex, to: secondTab) + 1
        return NSRange(location: paragraphRange.location + skip, length: paragraphRange.length - skip)
    }

    private static func inlineMarkdown(for range: NSRange, in attributed: NSAttributedString, suppressBold: Bool = false) -> String {
        var result = ""
        attributed.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
            let text = (attributed.string as NSString).substring(with: runRange)
            guard !text.isEmpty else { return }

            // Keep leading/trailing whitespace outside any markers so
            // wrapping doesn't produce malformed Markdown like "word **" .
            let leading = text.prefix { $0 == " " || $0 == "\t" }
            let trailing = text.reversed().prefix { $0 == " " || $0 == "\t" }
            let core = String(text.dropFirst(leading.count).dropLast(trailing.count))
            guard !core.isEmpty else {
                result += text
                return
            }

            var marked = core
            let font = attributes[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []

            if isMonospaced(font) {
                marked = "`\(marked)`"
            } else {
                if traits.contains(.italicFontMask) {
                    marked = "*\(marked)*"
                }
                if traits.contains(.boldFontMask), !suppressBold {
                    marked = "**\(marked)**"
                }
            }

            if let url = attributes[.link] as? URL {
                marked = "[\(marked)](\(url.absoluteString))"
            } else if let urlString = attributes[.link] as? String {
                marked = "[\(marked)](\(urlString))"
            }

            result += String(leading) + marked + String(trailing)
        }
        return result
    }

    // MARK: - Font heuristics

    private static func isMonospaced(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) { return true }
        let monospacedFamilies = ["menlo", "monaco", "courier", "sf mono", "consolas"]
        let family = (font.familyName ?? font.fontName).lowercased()
        return monospacedFamilies.contains { family.contains($0) }
    }

    /// Buckets a paragraph's font size into a heading level, using a
    /// generous size threshold so ordinary body text (~12-16pt in most rich
    /// text sources) never gets misread as a heading.
    private static func headingLevel(for font: NSFont?) -> Int? {
        guard let font else { return nil }
        let traits = NSFontManager.shared.traits(of: font)
        guard traits.contains(.boldFontMask) else { return nil }
        switch font.pointSize {
        case 20...: return 1
        case 17..<20: return 2
        case 15..<17: return 3
        default: return nil
        }
    }
}
