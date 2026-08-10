import SwiftUI
import AppKit

/// Posted by `FloatingPanel` when ⌘K is pressed, toggling the section
/// palette's presentation. Mirrors `.nickelFocusSearch` in
/// `SearchField.swift`, except `PanelView` doesn't focus an existing field in
/// response — it flips `SelectionModel.presentedOverlay`, which mounts a
/// fresh `SectionSwitcher` that focuses its own field as it appears.
///
/// The palette itself is selection-aware: with nothing selected, ⌘K opens it
/// in "switch" mode (search-and-switch the active section); with one or more
/// notes selected, it opens in "move" mode (search-and-move the selection
/// into a section) instead. Which mode is decided once, by `PanelView`, when
/// this notification is handled — see the `move` doc comment on
/// `PanelOverlay.sectionSwitcher`.
extension Notification.Name {
    static let nickelToggleSectionSwitcher = Notification.Name("NickelToggleSectionSwitcher")
}

/// The ⌘K command palette, in one of two modes (see `move` above):
///
/// - **Switch** (`move == false`): search-and-switch across "Show All",
///   every section, and (for a query that doesn't already match one)
///   creating a new section — followed, under a hairline, by the commands
///   that apply right now (`PaletteCommand`).
/// - **Move** (`move == true`): search-and-move the current selection into a
///   section — every matching section, plus "No Section" (ungroup), plus the
///   same "New Section" row — without touching `store.activeSection` or the
///   selection itself.
///
/// Presented as a dimmed overlay anchored near the top of the panel,
/// matching native command palettes.
struct SectionSwitcher: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions

    /// Snapshotted by `PanelView` at presentation time; see the `move` doc
    /// comment on `PanelOverlay.sectionSwitcher`.
    let move: Bool

    @State private var query = ""
    @State private var highlightedIndex = 0
    @Environment(\.controlActiveState) private var controlActiveState

    /// Whether the highlighted row draws with the emphasized (accent-filled,
    /// white-on-blue) treatment. Native lists only do that while their window
    /// is key; behind an inactive panel the palette drops to the unemphasized
    /// gray fill with normal label colors, matching `NoteRow`'s selection.
    private var isEmphasized: Bool { controlActiveState == .key }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.15)
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
            .padding(.vertical, 10)

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

    /// A single row in the palette's result list. `id` is a stable label
    /// (rather than an index) so `ForEach` diffs correctly as the query — and
    /// therefore the result set — changes on every keystroke. `.showAll` only
    /// appears in switch mode, `.noSection` only in move mode — see `results`.
    private enum Result: Identifiable {
        case showAll
        case section(String)
        case noSection
        case newSection(String)
        case command(PaletteCommand)

        var id: String {
            switch self {
            case .showAll: return "show-all"
            case .section(let name): return "section:\(name)"
            case .noSection: return "no-section"
            case .newSection(let name): return "new:\(name)"
            case .command(let command): return "command:\(command.title)"
            }
        }

        var isCommand: Bool {
            if case .command = self { return true }
            return false
        }

        var group: PaletteGroup { isCommand ? .command : .section }
    }

    /// Switch mode: "Show All" (if it matches), then every matching section,
    /// then — for a non-empty query that isn't already an exact
    /// (case-insensitive) section name — a trailing "New Section" row.
    ///
    /// Move mode: the same list with "No Section" (ungroup the selection)
    /// standing in for "Show All" — there's no "Show All" destination to
    /// move notes into.
    private var results: [Result] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        var candidates: [Result] = [move ? .noSection : .showAll]
        candidates += store.sections.map { .section($0) }
        candidates += PaletteCommand.applicable(in: paletteContext).map { .command($0) }

        var items = PaletteMatcher.ranked(
            candidates,
            query: trimmedQuery,
            group: { $0.group },
            label: { label(for: $0) }
        )

        // The "New Section" row closes out the destination list, exactly
        // where it sat before commands existed: after every matching
        // section, above the command block.
        if !trimmedQuery.isEmpty, !store.sections.contains(where: { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }) {
            let insertionIndex = items.firstIndex { $0.isCommand } ?? items.count
            items.insert(.newSection(trimmedQuery), at: insertionIndex)
        }

        return items
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

    private func label(for result: Result) -> String {
        switch result {
        case .showAll: return "Show All"
        case .section(let name): return name
        case .noSection: return "No Section"
        case .newSection(let name): return "New Section: “\(name)”"
        case .command(let command): return command.title
        }
    }

    /// Every section every currently-selected note belongs to, collapsed to
    /// a single value only when it's the same section (or ungrouped, `nil`)
    /// for *all* of them. The outer optional distinguishes "no uniform
    /// answer" (empty or mixed selection — no checkmark should show) from
    /// "uniform answer is ungrouped" (inner `nil` — `.noSection` should
    /// check).
    private var uniformSelectionSection: String?? {
        let sections = Set(store.activeNotes.filter { selection.selectedIDs.contains($0.id) }.map(\.listName))
        return sections.count == 1 ? sections.first : nil
    }

    private func isActive(_ result: Result) -> Bool {
        if move {
            guard let uniformSection = uniformSelectionSection else { return false }
            switch result {
            case .section(let name): return uniformSection == name
            case .noSection: return uniformSection == nil
            case .showAll, .newSection, .command: return false
            }
        }
        switch result {
        case .showAll: return store.activeSection == nil
        case .section(let name): return store.activeSection == name
        case .noSection, .newSection, .command: return false
        }
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

    private func commit(_ result: Result) {
        if move {
            // Move mode never touches `store.activeSection` or the
            // selection: `actions.move(toSection:)` only reassigns
            // `listName` on the already-selected notes. That includes the
            // "New Section" row — unlike switch mode's `createSection`,
            // which also activates the new section, `NoteStore.move` already
            // appends an unrecognized name to `sections` on its own, so
            // there's nothing else to do here.
            switch result {
            case .section(let name):
                actions.move(toSection: name)
            case .noSection:
                actions.move(toSection: nil)
            case .newSection(let name):
                actions.move(toSection: name)
            case .showAll, .command:
                break // Never produced by `results` in move mode.
            }
            dismiss()
            return
        }

        // Picking any destination leaves the Logbook: it lists cleared
        // notes, not a section's live ones, so switching sections behind it
        // would leave the panel showing something else entirely.
        switch result {
        case .showAll:
            selection.setShowingLogbook(false)
            store.setActiveSection(nil)
        case .section(let name):
            selection.setShowingLogbook(false)
            store.setActiveSection(name)
        case .newSection(let name):
            selection.setShowingLogbook(false)
            store.createSection(named: name)
        case .command(let command):
            // Dismiss first: some commands hand focus to another control
            // (an inline rename field) or raise a confirmation dialog, and
            // neither can happen behind the palette.
            dismiss()
            run(command)
            return
        case .noSection:
            break // Never produced by `results` in switch mode.
        }
        dismiss()
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

    /// Closes the palette in the same animation `PanelView.toggleOverlay`
    /// opens it with, so Esc, a click on the dim, and ⌘K all look identical.
    private func dismiss() {
        withAnimation(.panelOverlay) {
            selection.presentedOverlay = nil
        }
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
