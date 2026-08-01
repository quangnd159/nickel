import AppKit

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
    /// its own file-URL pasteboard item, in the same order.
    static func copy(notes: [Note], store: NoteStore) {
        guard !notes.isEmpty else { return }
        write(text: notes.map { line(for: $0) }.joined(separator: "\n\n"), attachmentsIn: notes, store: store)
    }

    /// Renders each note as a "- " bullet, with any internal newlines
    /// indented two spaces so wrapped lines stay part of the same bullet.
    /// Attachment-only notes bullet their filename(s) instead of body text.
    static func copyAsList(notes: [Note], store: NoteStore) {
        guard !notes.isEmpty else { return }
        let lines = notes.map { note in
            "- " + line(for: note).replacingOccurrences(of: "\n", with: "\n  ")
        }
        write(text: lines.joined(separator: "\n"), attachmentsIn: notes, store: store)
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

    /// Writes `text` as a plain string alongside one `NSURL` per attachment
    /// (visible order). If there are no attachments, this is byte-identical
    /// to writing just the string, as before this feature existed.
    ///
    /// The string is written *last*: `writeObjects` treats each object as its
    /// own pasteboard item, and putting the URLs first means a
    /// `.fileURL`-preferring consumer (Finder, Slack, ChatGPT) sees the files,
    /// while a string-preferring consumer still finds the `NSString` item
    /// further down the pasteboard's type list.
    private static func write(text: String, attachmentsIn notes: [Note], store: NoteStore) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let fileURLs = notes.flatMap { note in
            note.attachments.map { store.url(for: $0, in: note) as NSURL }
        }
        pasteboard.writeObjects(fileURLs + [text as NSString])
    }
}
