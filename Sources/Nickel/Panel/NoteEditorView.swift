import SwiftUI

/// The contents of a standalone note-editing window (see
/// `NoteEditorWindowManager`): the note's Markdown source in a full-window
/// plain-text editor, with any attachments shown read-only beneath it.
///
/// Unlike the panel's inline `NoteRow` editor, Return here just inserts a
/// newline — there's nothing to commit to, since every keystroke already
/// flows into the store (which debounces its own disk writes).
struct NoteEditorView: View {
    let noteID: UUID

    @EnvironmentObject private var store: NoteStore
    @State private var text: String
    @State private var isEditorFocused = false

    /// The initial text comes in from the window controller: `store` isn't
    /// reachable at `init` time, and `@State` needs its seed there.
    init(noteID: UUID, initialText: String) {
        self.noteID = noteID
        _text = State(initialValue: initialText)
    }

    private var note: Note? { store.activeNotes.first { $0.id == noteID } }

    var body: some View {
        VStack(spacing: 0) {
            NoteSourceTextView(text: $text, isFocused: $isEditorFocused)
                .accessibilityLabel("Note text")

            if let note, !note.attachments.isEmpty {
                Divider()
                attachmentsStrip(note)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: text) { _, newText in store.update(id: noteID, text: newText) }
        .onChange(of: note?.text) { _, storeText in adoptExternalEdit(storeText) }
    }

    /// The same note can be edited inline in the panel while this window is
    /// open. Whoever is typing wins: an external change is adopted only when
    /// this editor doesn't have focus, so a live edit here is never yanked
    /// out from under the cursor.
    private func adoptExternalEdit(_ storeText: String?) {
        guard let storeText, !isEditorFocused, storeText != text else { return }
        text = storeText
    }

    /// Attachments are read-only here — they're captured in the panel (drag,
    /// paste, the composer's paperclip) and this window edits text only.
    private func attachmentsStrip(_ note: Note) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(note.attachments) { attachment in
                    HStack(spacing: 6) {
                        AttachmentThumbnailView(
                            fileURL: store.url(for: attachment, in: note),
                            contentType: attachment.contentType,
                            size: 28
                        )
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        // Decorative: the filename alongside already labels
                        // the card.
                        .accessibilityHidden(true)

                        Text(attachment.filename)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
    }
}
