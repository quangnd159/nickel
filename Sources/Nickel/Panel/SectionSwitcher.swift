import SwiftUI
import AppKit

/// The command palette, opened in one of two modes by two distinct entry
/// points (⌘K vs. ⌃⌘M — see `move` below):
///
/// - **Switch** (`move == false`, ⌘K): search-and-switch across "Show All",
///   every section, and (for a query that doesn't already match one)
///   creating a new section — followed, under a hairline, by the commands
///   that apply right now (`PaletteCommand`). Doesn't touch the selection.
/// - **Move** (`move == true`, ⌃⌘M "Move to Section…"): search-and-move the
///   current selection into a section — every matching section, plus "No
///   Section" (ungroup), plus the same "New Section" row — without touching
///   `store.activeSection`. The selection itself is cleared on a successful
///   move (`PanelActions.move(toSection:)`).
///
/// Presented as a dimmed overlay anchored near the top of the panel,
/// matching native command palettes.
struct SectionSwitcher: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions
    @Environment(\.colorScheme) private var colorScheme

    /// Which mode the palette opened in — fixed by the entry point that
    /// opened it (⌘K vs. ⌃⌘M), not derived from the selection. See the type
    /// doc comment above.
    let move: Bool

    @State private var query = ""
    @State private var highlightedIndex = 0

    /// The selection count the move-mode header displays, captured once on
    /// appear so the title stays stable for the palette's whole lifetime —
    /// see `moveHeaderTitle`.
    @State private var frozenMoveCount: Int?
    @Environment(\.controlActiveState) private var controlActiveState

    /// Whether the highlighted row draws with the emphasized (accent-filled,
    /// white-on-blue) treatment. Native lists only do that while their window
    /// is key; behind an inactive panel the palette drops to the unemphasized
    /// gray fill with normal label colors, matching `NoteRow`'s selection.
    private var isEmphasized: Bool { controlActiveState == .key }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.overlayScrim(for: colorScheme)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    // The palette takes over the panel while it's up, so
                    // VoiceOver shouldn't wander into the list behind it.
                    .accessibilityAddTraits(.isModal)

                card
                    .frame(width: min(geometry.size.width - 48, 280))
                    .padding(.top, 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 0) {
            // Move mode acts on a selection the user may not see (it can
            // scroll off-screen, or belong to a since-left section) — unlike
            // switch mode, which only ever changes what's on screen, so it
            // needs no such header.
            if move {
                Text(moveHeaderTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                    .onAppear { frozenMoveCount = selection.selectedIDs.count }
            }

            SectionSwitcherField(
                text: $query,
                placeholder: move ? "Move to…" : "Switch to…",
                onMoveUp: { moveHighlight(-1) },
                onMoveDown: { moveHighlight(1) },
                onCommit: commitHighlighted,
                onCancel: dismiss
            )
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.top, move ? 4 : 10)
            .padding(.bottom, 10)

            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let rows = results
                        let firstCommandIndex = rows.firstIndex { $0.isCommand }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, result in
                            VStack(alignment: .leading, spacing: 2) {
                                // One hairline between the destinations and
                                // the commands below them (never at the very
                                // top, where there'd be nothing above it to
                                // separate).
                                if index == firstCommandIndex, index > 0 {
                                    Rectangle()
                                        .fill(.quaternary)
                                        .frame(height: 1)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                }

                                // A real `Button` (not a tap gesture) so the
                                // row is a control to VoiceOver and to any
                                // other assistive technology; `.plain` keeps
                                // the palette's own row styling intact.
                                Button { commit(result) } label: {
                                    resultRow(result, isHighlighted: index == highlightedIndex)
                                }
                                .buttonStyle(.plain)
                                .onHover { isHovering in
                                    if isHovering { highlightedIndex = index }
                                }
                            }
                            .id(result.id)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 240)
                // Keep the keyboard highlight visible: arrowing past the
                // visible slice scrolls the list to follow (hover-driven
                // highlight changes are already visible by definition, so
                // the scrollTo is a no-op for them).
                .onChange(of: highlightedIndex) { _, newIndex in
                    guard results.indices.contains(newIndex) else { return }
                    proxy.scrollTo(results[newIndex].id)
                }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
        .onChange(of: query) { _, _ in highlightedIndex = 0 }
    }

    private func resultRow(_ result: Result, isHighlighted: Bool) -> some View {
        // The selected-row label color only goes with the emphasized (accent)
        // fill; the unemphasized gray needs the normal label colors to stay
        // legible.
        let usesAccentFill = isHighlighted && isEmphasized
        let selectedLabel = Color(nsColor: .alternateSelectedControlTextColor)

        return HStack(spacing: 8) {
            // Commands carry a small symbol; destinations don't. That, plus
            // the hairline above the first command, is the whole distinction
            // — no color, no badge.
            if case .command(let command) = result {
                Image(systemName: command.symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(usesAccentFill ? selectedLabel : Color.secondary)
                    .frame(width: 14)
            }

            Text(label(for: result))
                .font(.system(size: 13))
                .foregroundStyle(usesAccentFill ? selectedLabel : Color.primary)
                .lineLimit(1)

            Spacer()

            if isActive(result) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(usesAccentFill ? selectedLabel : Color.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(highlightFill(isHighlighted: isHighlighted))
        )
        .contentShape(Rectangle())
    }

    private func highlightFill(isHighlighted: Bool) -> Color {
        guard isHighlighted else { return .clear }
        return isEmphasized
            ? Color(nsColor: .selectedContentBackgroundColor)
            : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    // MARK: - Results

    /// Thin wrapper over `SectionSwitcherLogic.results` with this view's live
    /// state — see that function's doc comment for the mode semantics.
    private var results: [Result] {
        SectionSwitcherLogic.results(sections: store.sections, move: move, query: query, paletteContext: paletteContext)
    }

    /// The state the command list's visibility rules read; see
    /// `PaletteCommand.isApplicable(in:)`.
    private var paletteContext: PaletteContext {
        let activeSection = store.activeSection
        return PaletteContext(
            isMoveMode: move,
            isShowingLogbook: selection.isShowingLogbook,
            activeSection: activeSection,
            hasDoneNotesInScope: activeSection.map(hasDoneNotes(inSection:)) ?? store.activeNotes.contains(where: \.isDone),
            hasDoneNotesInActiveSection: activeSection.map(hasDoneNotes(inSection:)) ?? false,
            hasNotesInScope: !selection.visibleOrder.isEmpty
        )
    }

    private func hasDoneNotes(inSection name: String) -> Bool {
        store.activeNotes.contains { $0.isDone && $0.listName == name }
    }

    /// "Move 1 Note to Section" / "Move N Notes to Section", shown above the
    /// search field only in move mode (see `card`). Reads the frozen count:
    /// committing clears the selection before the palette finishes its
    /// dismiss animation, and a live read would flash "Move 0 Notes" as it
    /// fades out.
    private var moveHeaderTitle: String {
        let count = frozenMoveCount ?? selection.selectedIDs.count
        return count == 1 ? "Move 1 Note to Section" : "Move \(count) Notes to Section"
    }

    private func label(for result: Result) -> String {
        SectionSwitcherLogic.label(for: result)
    }

    /// Thin wrapper over `SectionSwitcherLogic.uniformSelectionSection` —
    /// see that function's doc comment for what the double optional means.
    private var uniformSelectionSection: String?? {
        SectionSwitcherLogic.uniformSelectionSection(
            selectedListNames: store.activeNotes.filter { selection.selectedIDs.contains($0.id) }.map(\.listName)
        )
    }

    private func isActive(_ result: Result) -> Bool {
        SectionSwitcherLogic.isActive(
            result,
            move: move,
            uniformSelectionSection: uniformSelectionSection,
            activeSection: store.activeSection
        )
    }

    // MARK: - Interaction

    private func moveHighlight(_ direction: Int) {
        guard !results.isEmpty else { return }
        highlightedIndex = (highlightedIndex + direction + results.count) % results.count
    }

    private func commitHighlighted() {
        guard results.indices.contains(highlightedIndex) else { return }
        commit(results[highlightedIndex])
    }

    /// Executes the pure `SectionSwitcherLogic.commitAction` mapping for
    /// `result`; a `nil` action is a `(Result, move)` combination `results`
    /// never actually produces, so it's a no-op commit (just dismiss).
    private func commit(_ result: Result) {
        guard let action = SectionSwitcherLogic.commitAction(for: result, move: move) else {
            dismiss()
            return
        }

        switch action {
        case .move(let name):
            actions.move(toSection: name)
            dismiss()
        case .moveCreate(let name):
            // `actions.move(toSection:)` only reassigns `listName` on the
            // already-selected notes (and then clears the selection);
            // `NoteStore.move` already appends an unrecognized name to
            // `sections` on its own, so `.moveCreate` needs nothing more
            // than the same call — unlike switch mode's `createSection`,
            // which also activates the new section.
            actions.move(toSection: name)
            dismiss()
        case .switchTo(let name):
            // Picking any destination leaves the Logbook: it lists cleared
            // notes, not a section's live ones, so switching sections behind
            // it would leave the panel showing something else entirely.
            selection.setShowingLogbook(false)
            store.setActiveSection(name)
            dismiss()
        case .create(let name):
            selection.setShowingLogbook(false)
            store.createSection(named: name)
            dismiss()
        case .run(let command):
            // Dismiss first: some commands hand focus to another control
            // (an inline rename field) or raise a confirmation dialog, and
            // neither can happen behind the palette.
            dismiss()
            run(command)
        }
    }

    private func run(_ command: PaletteCommand) {
        switch command {
        case .newSection: actions.createAndRenameNewSection()
        case .renameSection: actions.renameActiveSection()
        case .dissolveSection: actions.dissolveActiveSection()
        case .deleteSection: actions.requestDeleteActiveSection()
        case .clearDone: actions.clearDoneInScope()
        case .clearDoneInSection: actions.clearDoneInActiveSection()
        case .openLogbook: actions.openLogbook()
        case .copyAllAsList: actions.copyAllAsList()
        case .settings: actions.openSettings()
        }
    }

    /// Closing is a plain state change, like every other way the palette is
    /// dismissed; `PanelView` owns the animation (see its
    /// `.animation(.panelOverlay, value:)`).
    private func dismiss() {
        selection.presentedOverlay = nil
    }
}

/// A borderless, single-line `NSTextField` for `SectionSwitcher`'s query.
///
/// Backed by `NSViewRepresentable` (rather than SwiftUI's `TextField` with
/// `.onKeyPress`, which the app's macOS 26 floor would technically support)
/// to match the established pattern of `SearchField`/`ComposerField`: Up/Down
/// need to drive the palette's highlighted row and Return/Esc need
/// context-independent commit/cancel behavior, all of which are cleanest to
/// intercept via `control(_:textView:doCommandBy:)`.
private struct SectionSwitcherField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Switch to…"
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 13)
            ]
        )
        field.stringValue = text
        field.lineBreakMode = .byTruncatingTail

        // The palette should feel instant, with no dead frame before typing
        // works — focus synchronously, then retry once on the next runloop
        // tick in case this fires mid-layout-pass (e.g. while `PanelView` is
        // still laying out the overlay), the same fallback `HeaderRenameField`
        // uses.
        field.window?.makeFirstResponder(field)
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }

        context.coordinator.field = field
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.onMoveUp = onMoveUp
        context.coordinator.onMoveDown = onMoveDown
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onMoveUp: onMoveUp, onMoveDown: onMoveDown, onCommit: onCommit, onCancel: onCancel)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        var onMoveUp: () -> Void
        var onMoveDown: () -> Void
        var onCommit: () -> Void
        var onCancel: () -> Void
        weak var field: NSTextField?

        init(
            text: Binding<String>,
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onCommit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                onMoveUp()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                onMoveDown()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
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
