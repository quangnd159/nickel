import AppKit
import UniformTypeIdentifiers

/// Writes notes to the general pasteboard, for the panel's Copy / Copy as
/// List actions.
///
/// The acceptance test this exists for: select a mixed batch of text notes
/// and image/file notes, ⌘C, then paste into a file-aware target (Finder,
/// Slack, ChatGPT, Claude Code) — the files arrive as real attachments — or a
/// text-only target, which still gets the equivalent plain text. Both
/// representations are written to the pasteboard in one pass, since a
/// consumer only reads whichever type it understands.
enum PasteboardWriter {
    /// Joins the notes' text with a blank line between each, in the order
    /// given (which should be visible order, not selection/insertion order).
    /// Attachment-only notes contribute their filename(s) in place of text;
    /// notes with both contribute text then filenames. Alongside that
    /// combined string, every attachment across the selection is written as
    /// its own pasteboard item, in the same order.
    static func copy(notes: [Note], store: NoteStore, pasteboard: NSPasteboard = .general) {
        guard !notes.isEmpty else { return }
        write(text: notes.map { line(for: $0) }.joined(separator: "\n\n"), attachmentsIn: notes, store: store, pasteboard: pasteboard)
    }

    /// Renders each note as a "- " bullet, with any internal newlines
    /// indented two spaces so wrapped lines stay part of the same bullet.
    /// Attachment-only notes bullet their filename(s) instead of body text.
    static func copyAsList(notes: [Note], store: NoteStore, pasteboard: NSPasteboard = .general) {
        guard !notes.isEmpty else { return }
        let lines = notes.map { note in
            "- " + line(for: note).replacingOccurrences(of: "\n", with: "\n  ")
        }
        write(text: lines.joined(separator: "\n"), attachmentsIn: notes, store: store, pasteboard: pasteboard)
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

    /// Writes one `NSPasteboardItem` per attachment (visible order), followed
    /// by one final item carrying `text` as a plain string. With no
    /// attachments, this is byte-identical to writing just the string, as
    /// before this feature existed.
    ///
    /// Every attachment item carries its file URL under `.fileURL`. If the
    /// attachment is an image, that *same* item also carries the image's raw
    /// bytes under its concrete UTI (e.g. `public.png`) — so a consumer takes
    /// whichever representation it understands (file-aware apps the URL,
    /// chat apps the image data, matching how a Finder/screenshot paste
    /// looks) without ever seeing the picture as two separate attachments.
    /// The string item is written *last*, after every attachment item, so a
    /// file- or image-data-preferring consumer sees those first while a
    /// string-preferring consumer still finds the plain-text item further
    /// down the pasteboard's type list.
    private static func write(text: String, attachmentsIn notes: [Note], store: NoteStore, pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        let attachmentItems = notes.flatMap { note in
            note.attachments.map { item(forAttachmentAt: store.url(for: $0, in: note)) }
        }

        let textItem = NSPasteboardItem()
        textItem.setString(text, forType: .string)

        pasteboard.writeObjects(attachmentItems + [textItem])
    }

    /// Builds the pasteboard item for one attachment: always its file URL,
    /// plus its raw image bytes under the concrete UTI when the file is an
    /// image and readable. Falls back silently to the file-URL-only item if
    /// the extension isn't an image type or the file can't be read.
    private static func item(forAttachmentAt url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)

        guard let utType = UTType(filenameExtension: url.pathExtension), utType.conforms(to: .image) else {
            return item
        }
        guard let data = try? Data(contentsOf: url) else {
            return item
        }
        item.setData(data, forType: NSPasteboard.PasteboardType(utType.identifier))
        return item
    }
}
