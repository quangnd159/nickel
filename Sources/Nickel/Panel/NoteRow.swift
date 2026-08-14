import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The note card's fixed metrics, shared by its SwiftUI content and by the
/// table's AppKit hit-testing so the two can't drift apart.
enum NoteRowMetrics {
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 13
    static let cornerRadius: CGFloat = 16
    /// The circle glyph's rendered width at 19pt — the same assumption the
    /// composer makes about its own circle.
    static let checkboxWidth: CGFloat = 19
    /// Gap between the checkbox and the note content.
    static let checkboxContentSpacing: CGFloat = 12

    /// One laid-out line of note text: 14pt system font with the 2pt line
    /// spacing the display text and the inline editor share.
    static let textLineHeight: CGFloat = 19

    /// Anything left of the checkbox's right edge plus half the gap to the
    /// note content counts as checkbox territory, so a click slightly above or
    /// below the glyph but still in that column is forgiven. The column runs
    /// the row's full height, so only `x` is ever checked.
    static var checkboxColumnWidth: CGFloat {
        horizontalPadding + checkboxWidth + checkboxContentSpacing / 2
    }

    /// How far below the last line of text the row's bottom sits: the card's
    /// bottom padding — which the 2pt selection stroke and the corner radius
    /// are drawn inside of — and then half the list's inter-row gap, since
    /// `NSTableView` splits `intercellSpacing` evenly above and below a row.
    ///
    /// Anything revealing the caret has to include all of it, or the card is
    /// left visibly unclosed at the bottom of the viewport.
    static var bottomChromeHeight: CGFloat {
        verticalPadding + NoteListMode.notes.rowSpacing / 2
    }

    /// How much has to be on screen below the top of the caret's line for the
    /// card to read as closed under it: the line itself, then the card's
    /// bottom chrome.
    ///
    /// Two things reveal the caret — the list's coordinated reveal when an
    /// edit opens (`NoteListCoordinator.PendingReveal`) and the editor's own
    /// caret follow while typing (`InlineNoteTextView.scrollRangeToVisible`).
    /// They both measure from here, so the first keystroke after opening an
    /// edit lands the view exactly where it already was.
    static func caretRevealHeight(lineHeight: CGFloat = textLineHeight) -> CGFloat {
        lineHeight + bottomChromeHeight
    }
}

/// A single note card: circle checkbox + note text (or an inline editor),
/// styled to match the Copper-style panel (white/dark-gray rounded card,
/// blue selection outline).
///
/// Purely the card's *look*, plus the inline editor. Clicks, double-clicks,
/// the context menu and selection belong to the `NSTableView` that hosts this
/// (see `NoteListTable`): a row's hosting view is invisible to the mouse
/// except while that row is the one being edited, so the table sees every
/// click and applies its own native selection.
///
/// The note is looked up by id rather than passed in as a value, so a cell
/// that stays put across a list update always renders the current note.
///
/// Display and edit both run through SwiftUI's own text engine (`Text` and a
/// self-sizing `NSTextView`) at the same 14pt/`.lineSpacing(2)` metrics, so
/// wrapping and height match by construction.
struct NoteRowContent: View {
    let noteID: UUID

    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions
    /// Mirrors the inline editor's first-responder state (see
    /// `InlineNoteEditorField`), the same pattern `ComposerField` and
    /// `NoteSourceTextView` use since `@FocusState` doesn't reach into an
    /// `NSViewRepresentable`.
    @State private var editFieldFocused: Bool = false
    @Environment(\.controlActiveState) private var controlActiveState

    private var note: Note? { store.notesByID[noteID] }

    private var isSelected: Bool { selection.selectedIDs.contains(noteID) }
    private var isEditing: Bool { selection.editingID == noteID }

    /// Selection outline color. AppKit draws selection with the accent color
    /// only while the window is key and drops to the unemphasized gray
    /// otherwise (`NSTableView`'s emphasized/unemphasized pair), so the row
    /// follows the same rule rather than staying vividly selected behind an
    /// inactive panel.
    private var selectionStroke: Color {
        controlActiveState == .key
            ? .accentColor
            : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }
    private static let attachmentsSpace = "NoteRow.attachments"

    var body: some View {
        if let note {
            card(note)
        }
    }

    private func card(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: NoteRowMetrics.checkboxContentSpacing) {
            // A plain glyph, not a button: the checkbox column's clicks are
            // caught by the table (see `NoteListCoordinator.handleClick`) so
            // they toggle done without ever touching the selection.
            // Hidden from accessibility rather than labeled: `.combine` on
            // the row would concatenate a label into the row's own text
            // ("Mark as Done, <note text>"), and the toggle is already
            // exposed as the row's named action (see below).
            Image(systemName: note.isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: NoteRowMetrics.checkboxWidth, weight: .light))
                .foregroundStyle(note.isDone ? .secondary : .quaternary)
                .frame(height: NoteRowMetrics.checkboxWidth)
                .accessibilityHidden(true)

            // `.identity` on both branches: the editor and the display text
            // render pixel-identically (same font, spacing, wrap width —
            // snapshot-verified), so the swap must be an instantaneous
            // replacement with the spring animating only the row's height.
            // The default opacity cross-fade reads as a one-frame text
            // flash on edit exit, because the AppKit-backed editor's layer
            // teardown doesn't fade in step with the SwiftUI `Text` fading
            // in. (Space expand/collapse swaps two SwiftUI `Text`s, whose
            // matched cross-fade is imperceptible — the asymmetry that made
            // the flash stand out.)
            Group {
                if isEditing {
                    editField
                        .transition(.identity)
                } else {
                    displayText(note)
                        .transition(.identity)
                }
            }
        }
        // Reads the row as one element (note text once, not a bag of static
        // texts) while editing keeps the text field individually reachable.
        // The done toggle is exposed as a named action, since the checkbox
        // glyph itself is decorative (the table owns its clicks).
        .noteRowAccessibility(
            isDone: note.isDone,
            isEditing: isEditing,
            toggleDone: { store.toggleDone(ids: [note.id]) }
        )
        .padding(.horizontal, NoteRowMetrics.horizontalPadding)
        .padding(.vertical, NoteRowMetrics.verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: NoteRowMetrics.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        // The selected look, drawn here rather than by `NSTableRowView`'s
        // default fill: an outline, not a filled highlight. `NoteListRowView`
        // suppresses AppKit's own selection drawing so this is the only one.
        .overlay(
            RoundedRectangle(cornerRadius: NoteRowMetrics.cornerRadius, style: .continuous)
                .strokeBorder(selectionStroke, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        )
        .coordinateSpace(name: Self.attachmentsSpace)
    }

    // MARK: - Editing / display subviews
    //
    // Split out of `body` (rather than inlined into its `Group`) because the
    // combined modifier chain otherwise took the type-checker too long to
    // solve ("the compiler is unable to type-check this expression in
    // reasonable time"); each computed property type-checks independently.

    private var editingTextBinding: Binding<String> {
        Binding(
            get: { selection.editingText },
            set: { selection.editingText = $0 }
        )
    }

    private var editField: some View {
        InlineNoteEditorField(
            text: editingTextBinding,
            isFocused: $editFieldFocused,
            onCommit: commitEdit,
            onCancel: { selection.endEditing() }
        )
        .onChange(of: editFieldFocused, commitOnFocusLoss)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isExpanded: Bool { selection.expandedIDs.contains(noteID) }

    @ViewBuilder
    private func displayText(_ note: Note) -> some View {
        // An attachment-only note (no text) skips the text view entirely
        // rather than rendering an empty `Text`, which would otherwise leave
        // an awkward blank line above the attachments.
        VStack(alignment: .leading, spacing: note.text.isEmpty ? 0 : 8) {
            if !note.text.isEmpty {
                if isExpanded {
                    // Full Markdown rendering: headings, lists, blockquotes
                    // and code blocks get their own block styling; nothing is
                    // line-clamped.
                    MarkdownBlocksView(text: note.text)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(note.isDone ? 0.5 : 1)
                } else {
                    // Collapsed 3-line preview: flattened to plain lines
                    // (block markers like "#"/"-"/">" stripped) with inline
                    // styling still applied, so the clamp behaves like simple
                    // wrapped text.
                    Text(MarkdownCache.collapsedPreview(for: note.text))
                        .font(.system(size: 14))
                        .lineSpacing(2)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(note.isDone ? 0.5 : 1)
                }
            }

            if !note.attachments.isEmpty {
                attachmentsView(note)
            }
        }
    }

    // MARK: - Attachments

    /// A single image attachment gets one big rounded thumbnail; anything
    /// else (a non-image file, or more than one attachment) renders as a
    /// stack of compact icon + filename cards.
    @ViewBuilder
    private func attachmentsView(_ note: Note) -> some View {
        if note.attachments.count == 1, isImage(note.attachments[0]) {
            imageThumbnail(note.attachments[0], in: note)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(note.attachments) { attachment in
                    attachmentCard(attachment, in: note)
                }
            }
        }
    }

    private func isImage(_ attachment: Attachment) -> Bool {
        UTType(attachment.contentType)?.conforms(to: .image) ?? false
    }

    private func imageThumbnail(_ attachment: Attachment, in note: Note) -> some View {
        AttachmentThumbnailView(fileURL: store.url(for: attachment, in: note), contentType: attachment.contentType, size: 64)
            .frame(maxHeight: 64)
            .fixedSize(horizontal: true, vertical: false)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
            .accessibilityLabel(attachment.filename)
            .reportingAttachmentFrame(id: attachment.id, in: Self.attachmentsSpace)
    }

    private func attachmentCard(_ attachment: Attachment, in note: Note) -> some View {
        HStack(spacing: 8) {
            AttachmentThumbnailView(fileURL: store.url(for: attachment, in: note), contentType: attachment.contentType, size: 28)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                // Decorative: the filename `Text` alongside it already
                // labels the card, so this icon would otherwise be a second,
                // redundant element.
                .accessibilityHidden(true)

            Text(attachment.filename)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
        )
        .reportingAttachmentFrame(id: attachment.id, in: Self.attachmentsSpace)
    }

    private func commitEdit() {
        guard isEditing else { return }
        actions.commitActiveEditIfAny()
    }

    // MARK: - Inline edit field focus
    //
    // `InlineNoteEditorField` (an `NSViewRepresentable`) owns focus-on-start
    // and Return/Escape handling directly at the field-editor level; this is
    // just the click-away commit that SwiftUI-level state still needs to
    // drive.

    /// Click-away commit: fires whenever the field's focus changes, which
    /// covers losing focus to another control (search field, composer,
    /// background click) as well as another `NoteRow` stealing focus when
    /// its own edit begins.
    private func commitOnFocusLoss(_ old: Bool, _ focused: Bool) {
        guard !focused, isEditing else { return }
        commitEdit()
    }

}

// MARK: - Inline editor text surface

/// The inline note editor's text surface: a borderless, self-sizing
/// `NSTextView`, the same control the ⌘↩ window editor uses
/// (`NoteSourceTextView`), rather than SwiftUI's `TextField(axis: .vertical)`
/// or an `NSTextField`.
///
/// `TextField` can't give Shift-Return and plain Return different behavior
/// (newline vs. commit) and always starts editing with everything selected.
/// An `NSTextField` was tried next and can't hold a paragraph style: the
/// cell reasserts its own plain attributes over the field editor, so the
/// display view's 2pt line spacing was silently dropped (verified by
/// snapshot — storage carried lineSpacing 2, the rendered text and the
/// cell's measured height didn't). Multiline editing with paragraph styles
/// is what `NSTextView` is for.
private struct InlineNoteEditorField: NSViewRepresentable {
    /// Matches `displayText`'s `.lineSpacing(2)`, so entering edit mode
    /// doesn't visibly reflow the text it replaces (in-place editing keeps
    /// the display metrics).
    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.lineBreakMode = .byWordWrapping
        return style
    }()

    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraphStyle,
    ]

    @Binding var text: String
    /// Mirrors the view's first-responder state, the same pattern
    /// `ComposerField` uses, so `NoteRow` can commit on focus loss.
    @Binding var isFocused: Bool
    /// Called when plain Return is pressed.
    var onCommit: () -> Void
    /// Called when Escape is pressed.
    var onCancel: () -> Void

    func makeNSView(context: Context) -> InlineNoteTextView {
        let view = InlineNoteTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.focusRingType = .none
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        // Not `isVerticallyResizable`: that's the in-a-scroll-view sizing
        // model and lets the view balloon toward `maxSize`; here SwiftUI
        // sizes the view from `intrinsicContentSize` alone. The container
        // keeps an unbounded height so layout never clips while the frame
        // catches up.
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // NSTextView's default vertical hugging is low (an NSTextField's is
        // high), so SwiftUI would stretch the view to the proposed height
        // instead of holding it at `intrinsicContentSize`.
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.font = .systemFont(ofSize: 14)
        view.textColor = .labelColor
        view.defaultParagraphStyle = Self.paragraphStyle
        view.typingAttributes = Self.textAttributes
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.textAttributes))
        view.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.isFocused.wrappedValue = focused
        }

        // Editing always starts on a freshly created view — `NoteRow` swaps
        // this in for `displayText` from scratch when it enters edit mode —
        // so this is the one moment to claim first responder and park the
        // caret at the end. Deferred a runloop turn, same as
        // `HeaderRenameField`: a view created mid-layout-pass can have
        // `makeFirstResponder` silently no-op.
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            // No scrolling from here. Revealing the caret is the list's job
            // and it does it in the same animation as the row's growth (see
            // `NoteListCoordinator.applyPendingReveal`) — a scroll issued
            // here would land after that animation as a separate, jarring
            // second motion.
        }
        return view
    }

    func updateNSView(_ nsView: InlineNoteTextView, context: Context) {
        if nsView.string != text {
            nsView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.textAttributes))
            nsView.invalidateIntrinsicContentSize()
        }
        context.coordinator.onCommit = onCommit
        context.coordinator.isFocused = $isFocused
    }

    /// Answers SwiftUI's size proposal synchronously — measuring the text at
    /// the proposed width — instead of leaving height to
    /// `intrinsicContentSize`, which is only correct one layout pass later
    /// (the container width isn't known at creation). Same-pass sizing is
    /// what lets `SelectionModel.beginEditing`'s spring interpolate the
    /// row's growth; the deferred intrinsic path landed outside the animated
    /// transaction and snapped.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InlineNoteTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let measured = NSAttributedString(string: nsView.string, attributes: Self.textAttributes)
            .boundingRect(
                with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            ).height
        return CGSize(width: width, height: max(ceil(measured), NSFont.systemFont(ofSize: 14).pointSize))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel, isFocused: $isFocused)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var onCommit: () -> Void
        private let onCancel: () -> Void
        var isFocused: Binding<Bool>

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void, isFocused: Binding<Bool>) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
            self.isFocused = isFocused
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Shift+Return: fall through to the default newline
                // insertion. Plain Return commits.
                if NSEvent.modifierFlags.contains(.shift) { return false }
                onCommit()
                endFocus(of: textView)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                endFocus(of: textView)
                return true
            }
            return false
        }

        /// Resigns first responder *after* the edit has ended. The editor
        /// stays on screen for the collapse animation, and while it remains
        /// first responder it keeps drawing its insertion point — which
        /// sweeps along the left margin as the shrinking frame rewraps the
        /// text (snapshot-confirmed). Ordered after `onCommit`/`onCancel` so
        /// the focus-loss commit path sees editing already over and stays a
        /// no-op (Escape must discard, not commit).
        private func endFocus(of textView: NSTextView) {
            textView.window?.makeFirstResponder(nil)
        }
    }
}

/// A non-scrolling `NSTextView` whose intrinsic height is its laid-out text
/// height, so the row grows and shrinks with the content the way
/// `GrowingTextField` does for the composer.
private final class InlineNoteTextView: NSTextView {
    /// Same asymmetric contract as `GrowingTextField.onFocusChange`; here
    /// both hooks are real overrides since an `NSTextView` is its own
    /// editor (no field-editor handoff).
    var onFocusChange: ((Bool) -> Void)?

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(layoutManager.usedRect(for: textContainer).height)
        )
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    /// `NSTextView` reveals the caret on every insertion, and its idea of the
    /// caret is the bare glyph rect — which, on the last line, seats the text
    /// flush against the bottom of the viewport and cuts off the card's
    /// padding, stroke and rounded corners. Extending the rect by the card's
    /// bottom chrome keeps the row visibly closed underneath the caret. Still
    /// a minimal scroll: `scrollToVisible` moves the least it can, and the
    /// extension is capped at the row's own bottom so it never reveals past
    /// the card.
    override func scrollRangeToVisible(_ range: NSRange) {
        guard let layoutManager, let textContainer else {
            super.scrollRangeToVisible(range)
            return
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        rect.size.height = min(
            NoteRowMetrics.caretRevealHeight(lineHeight: rect.height),
            bounds.maxY + NoteRowMetrics.bottomChromeHeight - rect.minY
        )
        scrollToVisible(rect)
    }

    /// A width change rewraps the text, so the height must be remeasured.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onFocusChange?(true) }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign { onFocusChange?(false) }
        return didResign
    }
}

// MARK: - Attachment hit-testing

/// One attachment's on-screen frame, in the row's own (top-left origin)
/// coordinate space — which is also the hosting view's, so the table can
/// hit-test a double-click against it directly.
struct NoteAttachmentFrame: Equatable {
    let id: UUID
    let frame: CGRect
}

struct NoteAttachmentFramesKey: PreferenceKey {
    static var defaultValue: [NoteAttachmentFrame] = []
    static func reduce(value: inout [NoteAttachmentFrame], nextValue: () -> [NoteAttachmentFrame]) {
        value += nextValue()
    }
}

private extension View {
    /// Exposes a note row as a single VoiceOver element: `.combine` merges
    /// the checkbox and note text into one readable label, the done state
    /// becomes the element's value, and toggling it is a named action
    /// (rather than a separately focusable nested button, which `.combine`
    /// doesn't preserve). While editing, children stay individually
    /// reachable so the inline text field keeps normal VoiceOver behavior.
    func noteRowAccessibility(isDone: Bool, isEditing: Bool, toggleDone: @escaping () -> Void) -> some View {
        self
            .accessibilityElement(children: isEditing ? .contain : .combine)
            .accessibilityValue(isEditing ? "" : (isDone ? "Done" : "Not Done"))
            .accessibilityAction(named: Text(isDone ? "Mark as Not Done" : "Mark as Done"), toggleDone)
    }

    /// Publishes this view's frame (in the named coordinate space) as a
    /// `NoteAttachmentFramesKey` entry for `id`, so the table can hit-test a
    /// double-click against it without the attachment view needing a gesture
    /// recognizer of its own — see `NoteListCoordinator.handleDoubleClick`.
    func reportingAttachmentFrame(id: UUID, in coordinateSpace: String) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: NoteAttachmentFramesKey.self,
                    value: [NoteAttachmentFrame(id: id, frame: geometry.frame(in: .named(coordinateSpace)))]
                )
            }
        )
    }
}
