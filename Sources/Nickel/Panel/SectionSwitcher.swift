import SwiftUI
import AppKit

/// Posted by `FloatingPanel` when ⌘K is pressed, toggling the section
/// switcher's presentation. Mirrors `.nickelFocusSearch` in
/// `SearchField.swift`, except `PanelView` doesn't focus an existing field in
/// response — it flips `SelectionModel.presentedOverlay`, which mounts a
/// fresh `SectionSwitcher` that focuses its own field as it appears.
extension Notification.Name {
    static let nickelToggleSectionSwitcher = Notification.Name("NickelToggleSectionSwitcher")
}

/// The ⌘K command palette: search-and-switch across "Show All", every
/// section, and (for a query that doesn't already match one) creating a new
/// section. Presented as a dimmed overlay anchored near the top of the
/// panel, matching native command palettes.
struct SectionSwitcher: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel

    @State private var query = ""
    @State private var highlightedIndex = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.15)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

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
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            resultRow(result, isHighlighted: index == highlightedIndex)
                                .onTapGesture { commit(result) }
                                .onHover { isHovering in
                                    if isHovering { highlightedIndex = index }
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        )
        .onChange(of: query) { _, _ in highlightedIndex = 0 }
    }

    private func resultRow(_ result: Result, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label(for: result))
                .font(.system(size: 13))
                .foregroundStyle(isHighlighted ? .white : .primary)
                .lineLimit(1)

            Spacer()

            if isActive(result) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHighlighted ? .white : .secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Results

    /// A single row in the palette's result list. `id` is a stable label
    /// (rather than an index) so `ForEach` diffs correctly as the query — and
    /// therefore the result set — changes on every keystroke.
    private enum Result: Identifiable {
        case showAll
        case section(String)
        case newSection(String)

        var id: String {
            switch self {
            case .showAll: return "show-all"
            case .section(let name): return "section:\(name)"
            case .newSection(let name): return "new:\(name)"
            }
        }
    }

    /// "Show All" (if it matches), then every matching section, then — for a
    /// non-empty query that isn't already an exact (case-insensitive) section
    /// name — a trailing "New Section" row.
    private var results: [Result] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [Result] = []

        if trimmedQuery.isEmpty || "Show All".localizedCaseInsensitiveContains(trimmedQuery) {
            items.append(.showAll)
        }

        for sectionName in store.sections where trimmedQuery.isEmpty || sectionName.localizedCaseInsensitiveContains(trimmedQuery) {
            items.append(.section(sectionName))
        }

        if !trimmedQuery.isEmpty, !store.sections.contains(where: { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }) {
            items.append(.newSection(trimmedQuery))
        }

        return items
    }

    private func label(for result: Result) -> String {
        switch result {
        case .showAll: return "Show All"
        case .section(let name): return name
        case .newSection(let name): return "New Section: “\(name)”"
        }
    }

    private func isActive(_ result: Result) -> Bool {
        switch result {
        case .showAll: return store.activeSection == nil
        case .section(let name): return store.activeSection == name
        case .newSection: return false
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
        switch result {
        case .showAll:
            store.setActiveSection(nil)
        case .section(let name):
            store.setActiveSection(name)
        case .newSection(let name):
            store.createSection(named: name)
        }
        dismiss()
    }

    private func dismiss() {
        selection.presentedOverlay = nil
    }
}

/// A borderless, single-line `NSTextField` for `SectionSwitcher`'s query.
///
/// Backed by `NSViewRepresentable` (rather than SwiftUI's `TextField` with
/// `.onKeyPress`, which the app's macOS 14 floor would technically support)
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
