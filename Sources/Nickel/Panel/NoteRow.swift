import SwiftUI

/// A single note card: circle checkbox + note text, styled to match the
/// Copper-style panel (white/dark-gray rounded card).
struct NoteRow: View {
    let note: Note
    let onToggleDone: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggleDone) {
                Image(systemName: note.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(note.isDone ? .secondary : .tertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            Text(renderedText)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(note.isDone ? 0.5 : 1)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
    }

    private var renderedText: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: note.text, options: options)) ?? AttributedString(note.text)
    }
}
