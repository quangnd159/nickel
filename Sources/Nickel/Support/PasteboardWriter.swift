import AppKit
import UniformTypeIdentifiers

/// Writes notes to the general pasteboard, for the panel's Copy / Copy as
/// List actions.
///
/// The acceptance test this exists for: select a mixed batch of text notes
/// and image/file notes, ⌘C, then paste into a chat app — the text is
/// inserted AND the images attach — or into a file-aware target (Finder,
/// Slack, ChatGPT), which gets real file attachments, or a plain-text
/// target, which still gets the equivalent text. A single-path paste
/// handler reads one representation and stops, so every representation of
/// the same content is written as multiple *representations of one item*
/// where that's what the format supports (Apple's pasteboard model), plus
/// separate items where a consumer needs a real file:
///
/// 1. One rich item first, carrying RTFD (text with inline `NSTextAttachment`
///    images, the same thing TextEdit/Mail/Notes write on copy), RTF (images
///    dropped automatically by RTF's format), and plain string — so a rich
///    reader gets text-and-images in one paste.
/// 2. Then one item per attachment, unchanged: file URL, plus raw image
///    bytes under the concrete UTI when it's an image — for file-aware or
///    image-data-only consumers (Finder, browser `clipboardData.files`).
enum PasteboardWriter {
    /// Joins the notes' text with a blank line between each, in the order
    /// given (which should be visible order, not selection/insertion order).
    /// Attachment-only notes contribute their filename(s) in place of text;
    /// notes with both contribute text then filenames. Alongside that
    /// combined string, every attachment across the selection is written as
    /// its own pasteboard item, in the same order.
    static func copy(notes: [Note], store: NoteStore, pasteboard: NSPasteboard = .general) {
        guard !notes.isEmpty else { return }
        let text = notes.map { line(for: $0) }.joined(separator: "\n\n")
        let rich = joined(notes.map { attributedLine(for: $0, store: store) }, separator: "\n\n")
        write(text: text, rich: rich, attachmentsIn: notes, store: store, pasteboard: pasteboard)
    }

    /// Renders each note as a "- " bullet, with any internal newlines
    /// indented two spaces so wrapped lines stay part of the same bullet.
    /// Attachment-only notes bullet their filename(s) instead of body text.
    static func copyAsList(notes: [Note], store: NoteStore, pasteboard: NSPasteboard = .general) {
        guard !notes.isEmpty else { return }
        let lines = notes.map { note in
            "- " + line(for: note).replacingOccurrences(of: "\n", with: "\n  ")
        }
        let text = lines.joined(separator: "\n")
        let richLines = notes.map { note -> NSAttributedString in
            let bulleted = NSMutableAttributedString(string: "- ")
            bulleted.append(attributedLine(for: note, store: store, newlineIndent: "  "))
            return bulleted
        }
        let rich = joined(richLines, separator: "\n")
        write(text: text, rich: rich, attachmentsIn: notes, store: store, pasteboard: pasteboard)
    }

    /// A note's textual representation for the combined string: its text,
    /// followed by its attachments' filenames (comma-joined) on their own
    /// line — so a text-only consumer still sees that files belonged to the
    /// note. Attachment-only notes contribute just the filenames; text-only
    /// notes just their text.
    private static func line(for note: Note) -> String {
        let filenames = note.attachments.map(\.filename).joined(separator: ", ")
        if note.text.isEmpty { return filenames }
        if filenames.isEmpty { return note.text }
        return note.text + "\n" + filenames
    }

    /// The rich (attributed) counterpart of `line(for:)`: the note's text,
    /// then each attachment on the same trailing line. Image attachments
    /// are embedded as an `NSTextAttachment` (name + bytes preserved via its
    /// `NSFileWrapper`) instead of their filename text; non-image
    /// attachments still contribute filename text, matching `line(for:)`.
    /// `newlineIndent` mirrors the two-space indent `copyAsList` applies to
    /// wrapped lines.
    private static func attributedLine(for note: Note, store: NoteStore, newlineIndent: String = "") -> NSAttributedString {
        let result = NSMutableAttributedString()
        if !note.text.isEmpty {
            result.append(NSAttributedString(string: note.text))
        }
        for (index, attachment) in note.attachments.enumerated() {
            if index == 0 {
                if result.length > 0 {
                    result.append(NSAttributedString(string: "\n" + newlineIndent))
                }
            } else {
                result.append(NSAttributedString(string: ", "))
            }
            let url = store.url(for: attachment, in: note)
            if let info = imageInfo(at: url) {
                let wrapper = FileWrapper(regularFileWithContents: info.data)
                wrapper.preferredFilename = attachment.filename
                let textAttachment = NSTextAttachment()
                textAttachment.fileWrapper = wrapper
                result.append(NSAttributedString(attachment: textAttachment))
            } else {
                result.append(NSAttributedString(string: attachment.filename))
            }
        }
        return result
    }

    /// Concatenates attributed strings with a plain-string separator between
    /// each, mirroring `[String].joined(separator:)`.
    private static func joined(_ pieces: [NSAttributedString], separator: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, piece) in pieces.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: separator)) }
            result.append(piece)
        }
        return result
    }

    /// Writes the rich item first, then one `NSPasteboardItem` per
    /// attachment (visible order). With no image attachments anywhere in
    /// the batch, the rich item degrades to a lone plain-string item, so a
    /// text-only copy stays byte-identical to writing just the string, as
    /// before this feature existed.
    ///
    /// Every attachment item carries its file URL under `.fileURL`. If the
    /// attachment is an image, that *same* item also carries the image's raw
    /// bytes under its concrete UTI (e.g. `public.png`) — so a consumer takes
    /// whichever representation it understands (file-aware apps the URL,
    /// chat apps the image data, matching how a Finder/screenshot paste
    /// looks) without ever seeing the picture as two separate attachments.
    private static func write(text: String, rich: NSAttributedString, attachmentsIn notes: [Note], store: NoteStore, pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        let attachmentItems = notes.flatMap { note in
            note.attachments.map { item(forAttachmentAt: store.url(for: $0, in: note)) }
        }

        pasteboard.writeObjects([richItem(for: rich, fallbackText: text)] + attachmentItems)
    }

    /// Builds the first pasteboard item: RTFD + RTF + plain string when the
    /// rich content actually embeds an image, otherwise just the plain
    /// string (see `write`'s doc comment on why that degrade path matters).
    /// If RTFD serialization fails, the item still gets RTF + string.
    private static func richItem(for rich: NSAttributedString, fallbackText: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        guard containsImageAttachment(rich) else {
            item.setString(fallbackText, forType: .string)
            return item
        }

        let range = NSRange(location: 0, length: rich.length)
        if let rtfdData = try? rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
            item.setData(rtfdData, forType: .rtfd)
        }
        if let rtfData = try? rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            item.setData(rtfData, forType: .rtf)
        }
        item.setString(fallbackText, forType: .string)
        return item
    }

    private static func containsImageAttachment(_ attributed: NSAttributedString) -> Bool {
        var found = false
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Builds the pasteboard item for one attachment: always its file URL,
    /// plus its raw image bytes under the concrete UTI when the file is an
    /// image and readable. Falls back silently to the file-URL-only item if
    /// the extension isn't an image type or the file can't be read.
    private static func item(forAttachmentAt url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)

        guard let info = imageInfo(at: url) else { return item }
        item.setData(info.data, forType: NSPasteboard.PasteboardType(info.utType.identifier))
        return item
    }

    /// The concrete image UTI and raw bytes for a file at `url`, or `nil` if
    /// its extension isn't an image type or the file can't be read.
    private static func imageInfo(at url: URL) -> (utType: UTType, data: Data)? {
        guard let utType = UTType(filenameExtension: url.pathExtension), utType.conforms(to: .image) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return (utType, data)
    }
}
