import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A single note card: circle checkbox + note text (or an inline editor),
/// styled to match the Copper-style panel (white/dark-gray rounded card,
/// blue selection outline). Handles click-to-select (with ⌘/⇧ modifiers),
/// double-click-to-edit, and the note's context menu.
///
/// Display and edit both run through SwiftUI's own text engine (`Text` and
/// `TextField(axis: .vertical)`) at the same 14pt/`.lineSpacing(2)` metrics,
/// so wrapping and height match by construction.
struct NoteRow: View {
    let note: Note
    let onToggleDone: () -> Void

    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions
    /// Mirrors the inline editor's first-responder state (see
    /// `InlineNoteEditorField`), the same pattern `ComposerField` and
    /// `NoteSourceTextView` use since `@FocusState` doesn't reach into an
    /// `NSViewRepresentable`.
    @State private var editFieldFocused: Bool = false
    @Environment(\.controlActiveState) private var controlActiveState

    /// Frames (in the row's own coordinate space, see `attachmentsSpace`) of
    /// each rendered attachment thumbnail/card, kept live via
    /// `AttachmentFramesPreferenceKey`. Used to tell whether a double-click
    /// landed on an attachment (open the file) rather than elsewhere on the
    /// card (begin editing).
    @State private var attachmentFrames: [AttachmentFrame] = []

    /// The checkbox `Button`'s live frame (in `attachmentsSpace`), kept via
    /// `CheckboxFramePreferenceKey`. Lets `isInCheckboxColumn` hit-test
    /// against the checkbox's actual measured position instead of a
    /// hand-summed constant that would silently drift out of sync with the
    /// card's padding or the HStack's spacing.
    @State private var checkboxFrame: CGRect = .zero

    private var isSelected: Bool { selection.selectedIDs.contains(note.id) }
    private var isEditing: Bool { selection.editingID == note.id }

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

    /// Gap between the checkbox and the note content. Shared by the HStack
    /// below and `isInCheckboxColumn`'s column-extension math so the two
    /// stay in sync instead of duplicating the value.
    private static let checkboxContentSpacing: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: Self.checkboxContentSpacing) {
            Button(action: onToggleDone) {
                Image(systemName: note.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(note.isDone ? .secondary : .quaternary)
                    .frame(height: 19)
            }
            .buttonStyle(.plain)
            // Hidden from accessibility rather than labeled: `.combine` on
            // the row would concatenate a label into the row's own text
            // ("Mark as Done, <note text>"), and the toggle is already
            // exposed as the row's named action (see below).
            .accessibilityHidden(true)
            .reportingCheckboxFrame(in: Self.attachmentsSpace)

            Group {
                if isEditing {
                    editField
                } else {
                    displayText
                }
            }
        }
        // Reads the row as one element (note text once, not a bag of static
        // texts) while editing keeps the text field individually reachable.
        // `.combine` gives a nested `Button` an implicit button trait on the
        // whole row without carrying over its tap handler, so the toggle is
        // exposed explicitly as a named action instead of relying on that.
        .noteRowAccessibility(isDone: note.isDone, isEditing: isEditing, toggleDone: onToggleDone)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selectionStroke, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        )
        .coordinateSpace(name: Self.attachmentsSpace)
        .onPreferenceChange(AttachmentFramesPreferenceKey.self) { attachmentFrames = $0 }
        .onPreferenceChange(CheckboxFramePreferenceKey.self) { checkboxFrame = $0 }
        .background(RightClickPreSelector { actions.selectOnRightClick(note.id) })
        // Row-wide click target: clicking anywhere on the card (including its
        // padding) selects it. One count:1 recognizer handles both clicks:
        // it fires on every mouse-up (so click-to-select is immediate, no
        // double-click-window wait), and the second click of a double-click
        // is told apart by `NSEvent.clickCount` — a simultaneous count:2
        // `SpatialTapGesture` never fires once a count:1 recognizer has
        // already succeeded on the same view. `simultaneousGesture` (rather
        // than `onTapGesture`) so the checkbox `Button`'s own tap handling
        // isn't excluded; the handlers instead explicitly ignore hits that
        // land in the checkbox column (see `isInCheckboxColumn`, which
        // hit-tests against the checkbox's measured frame rather than a
        // hand-summed constant) so the checkbox stays selection-inert (a
        // pure work-tracking control, Copper/Reminders/Things-style).
        .contentShape(Rectangle())
        .simultaneousGesture(
            SpatialTapGesture(count: 1).onEnded { value in handleClick(at: value.location) }
        )
        .contextMenu { contextMenuContent }
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

    private var isExpanded: Bool { selection.expandedIDs.contains(note.id) }

    @ViewBuilder
    private var displayText: some View {
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
                    Text(renderedText)
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
                attachmentsView
            }
        }
    }

    // MARK: - Attachments

    /// A single image attachment gets one big rounded thumbnail; anything
    /// else (a non-image file, or more than one attachment) renders as a
    /// stack of compact icon + filename cards.
    @ViewBuilder
    private var attachmentsView: some View {
        if note.attachments.count == 1, isImage(note.attachments[0]) {
            imageThumbnail(note.attachments[0])
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(note.attachments) { attachment in
                    attachmentCard(attachment)
                }
            }
        }
    }

    private func isImage(_ attachment: Attachment) -> Bool {
        UTType(attachment.contentType)?.conforms(to: .image) ?? false
    }

    private func imageThumbnail(_ attachment: Attachment) -> some View {
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

    private func attachmentCard(_ attachment: Attachment) -> some View {
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

    /// Opens `attachment`'s file in its default app (double-click only —
    /// see `handleDoubleClick`). No `QLPreviewPanel`: that's a
    /// nonactivating-panel focus headache this app doesn't need.
    private func openAttachment(id: UUID) {
        guard let attachment = note.attachments.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(store.url(for: attachment, in: note))
    }

    // MARK: - Click handling

    /// Anything left of the checkbox's measured right edge, plus half the
    /// gap to the note content, counts as checkbox territory — a click
    /// slightly above or below the 19×19 glyph but still in that column is
    /// forgiven, matching the full-height column this used to compute from
    /// hand-summed constants. `y` isn't checked at all: the column runs the
    /// row's full height.
    private func isInCheckboxColumn(_ location: CGPoint) -> Bool {
        location.x < checkboxFrame.maxX + Self.checkboxContentSpacing / 2
    }

    /// Dispatches on `NSEvent.clickCount` (see the gesture comment in
    /// `body`): the second mouse-up of a double-click re-enters here with
    /// `clickCount == 2` after the first was already handled as a single.
    private func handleClick(at location: CGPoint) {
        if NSApp.currentEvent?.clickCount == 2 {
            handleDoubleClick(at: location)
        } else {
            handleSingleClick(at: location)
        }
    }

    private func handleSingleClick(at location: CGPoint) {
        guard !isInCheckboxColumn(location) else { return }
        // Clicking another row while this one is mid-edit steals focus,
        // which fires `editFocus`'s `onChange` and commits — but that's a
        // separate view instance's state, so it can lose a race against the
        // selection mutation below if both land in the same tick. Committing
        // explicitly here first guarantees the previously-edited note's text
        // is saved before selection moves on.
        actions.commitActiveEditIfAny()
        guard !isEditing else { return }
        // Selecting a row this way is a click outside any text field, so it
        // should behave like the background click handler and give up text
        // focus (composer or search field) — otherwise `FloatingPanel`'s
        // `isEditingText` gate keeps suppressing list keyboard shortcuts.
        NSApp.keyWindow?.makeFirstResponder(nil)
        let flags = NSEvent.modifierFlags
        selection.handleClick(on: note.id, shift: flags.contains(.shift), command: flags.contains(.command))
    }

    private func handleDoubleClick(at location: CGPoint) {
        guard !isInCheckboxColumn(location) else { return }
        actions.commitActiveEditIfAny()
        // Double-clicking an attachment thumbnail/card opens the file
        // instead of entering edit mode — checked by hit-testing the tracked
        // frames rather than a gesture on the attachment view itself, so a
        // single click there still falls through to this row's own
        // selection handling untouched.
        if let hitID = attachmentFrames.first(where: { $0.frame.contains(location) })?.id {
            openAttachment(id: hitID)
            return
        }
        guard !isEditing else { return }
        let flags = NSEvent.modifierFlags
        guard !flags.contains(.command), !flags.contains(.shift) else { return }
        beginEditing()
    }

    private func beginEditing() {
        selection.selectSingle(note.id)
        selection.beginEditing(id: note.id, text: note.text)
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

    /// Collapsed preview text: block markers (heading `#`, list `-`/`1.`,
    /// blockquote `>`) are stripped so the 3-line clamp reads as plain
    /// wrapped text, while inline styling (bold/italic/links/code) still
    /// renders via `AttributedString(markdown:, options:
    /// .inlineOnlyPreservingWhitespace)`. Falls back to plain text if that
    /// fails to parse. Memoized in `MarkdownCache` — see its doc comment for
    /// why: rows are eager `VStack` children, so every row's `body` (and
    /// this property) re-evaluates on every store change, not just the row
    /// that actually changed.
    private var renderedText: AttributedString {
        MarkdownCache.collapsedPreview(for: note.text)
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("Copy") { actions.copy() }
            .panelKeyboardShortcut(.copy)

        Button("Copy as List") { actions.copyAsList() }
            .panelKeyboardShortcut(.copyAsList)

        Divider()

        Button(actions.allSelectedAreDone ? "Mark as Not Done" : "Mark as Done") {
            actions.toggleDone()
        }
        .panelKeyboardShortcut(.toggleDone)

        Button(actions.allSelectedAreExpanded ? "Collapse" : "Expand") {
            actions.toggleExpanded()
        }
        .panelKeyboardShortcut(.toggleExpanded)
        .disabled(selection.selectedIDs.isEmpty)

        Button("Edit") { actions.startEditingIfSingleSelected() }
            .panelKeyboardShortcut(.edit)
            .disabled(selection.selectedIDs.count != 1)

        Button("Edit in New Window") { actions.editInNewWindow() }
            .panelKeyboardShortcut(.editInNewWindow)
            .disabled(selection.selectedIDs.count != 1)

        Button("Merge Notes") { actions.merge() }
            .panelKeyboardShortcut(.merge)
            .disabled(selection.selectedIDs.count < 2)

        Menu("Move to Section") {
            ForEach(store.sections, id: \.self) { sectionName in
                Button(sectionName) { actions.move(toSection: sectionName) }
            }
            Button("No Section") { actions.move(toSection: nil) }
            Divider()
            Button("New Section with Selection") { actions.createSectionWithSelection() }
        }

        Divider()

        Button("Delete") { actions.delete() }
            .panelKeyboardShortcut(.delete)
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
            // Reveal the caret, the standard focus behavior. The enclosing
            // scroll view is the panel's note list (SwiftUI's `ScrollView`
            // is `NSScrollView`-backed), so this scrolls the list to the end
            // of a note taller than the preview it replaced. Deferred one
            // more turn *and* forced through `layoutIfNeeded`: the row's
            // grown height propagates through SwiftUI layout asynchronously,
            // and scrolling before it lands measures the caret against a
            // stale frame (seen as the reveal stopping a line short).
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.window?.layoutIfNeeded()
                view.scrollRangeToVisible(view.selectedRange())
                // `scrollRangeToVisible` stops exactly at the caret's line,
                // which leaves the card's bottom chrome below it (the row's
                // 13pt vertical padding plus the 2pt selection stroke)
                // clipped when editing begins at the end of a note near the
                // viewport bottom. Also reveal that strip; a no-op when
                // it's already on screen.
                let bottomChrome: CGFloat = 15
                view.scrollToVisible(NSRect(
                    x: 0, y: view.bounds.maxY,
                    width: view.bounds.width, height: bottomChrome
                ))
            }
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
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                return true
            }
            return false
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

/// One attachment's on-screen frame, reported in `NoteRow.attachmentsSpace`
/// so `handleDoubleClick` can tell whether a click landed on it.
private struct AttachmentFrame: Equatable {
    let id: UUID
    let frame: CGRect
}

private struct AttachmentFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [AttachmentFrame] = []
    static func reduce(value: inout [AttachmentFrame], nextValue: () -> [AttachmentFrame]) {
        value += nextValue()
    }
}

/// The checkbox `Button`'s on-screen frame, reported in
/// `NoteRow.attachmentsSpace` so `isInCheckboxColumn` can hit-test against
/// it instead of a hand-summed constant.
private struct CheckboxFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
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

    /// Publishes this view's frame (in the named coordinate space) as an
    /// `AttachmentFramesPreferenceKey` entry for `id`, so an ancestor can
    /// hit-test clicks against it without the attachment view needing its
    /// own gesture recognizer (which would otherwise double-fire alongside
    /// the row's own click handling — see `NoteRow.handleDoubleClick`).
    func reportingAttachmentFrame(id: UUID, in coordinateSpace: String) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: AttachmentFramesPreferenceKey.self,
                    value: [AttachmentFrame(id: id, frame: geometry.frame(in: .named(coordinateSpace)))]
                )
            }
        )
    }

    /// Publishes this view's frame (in the named coordinate space) as the
    /// `CheckboxFramePreferenceKey` value, so an ancestor can hit-test clicks
    /// against the checkbox's actual measured position — see
    /// `NoteRow.isInCheckboxColumn`.
    func reportingCheckboxFrame(in coordinateSpace: String) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: CheckboxFramePreferenceKey.self,
                    value: geometry.frame(in: .named(coordinateSpace))
                )
            }
        )
    }
}
