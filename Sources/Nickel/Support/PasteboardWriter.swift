import AppKit

/// Writes notes to the general pasteboard as plain text, for the panel's
/// Copy / Copy as List actions.
enum PasteboardWriter {
    /// Joins the notes' text with a blank line between each, in the order
    /// given (which should be visible order, not selection/insertion order).
    static func copy(notes: [Note]) {
        guard !notes.isEmpty else { return }
        write(notes.map(\.text).joined(separator: "\n\n"))
    }

    /// Renders each note as a "- " bullet, with any internal newlines
    /// indented two spaces so wrapped lines stay part of the same bullet.
    static func copyAsList(notes: [Note]) {
        guard !notes.isEmpty else { return }
        let lines = notes.map { note in
            "- " + note.text.replacingOccurrences(of: "\n", with: "\n  ")
        }
        write(lines.joined(separator: "\n"))
    }

    private static func write(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
