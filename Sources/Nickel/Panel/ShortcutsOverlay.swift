import SwiftUI

/// Posted by `FloatingPanel` when ⌘/ is pressed, toggling the keyboard
/// shortcuts card's presentation. Mirrors `.nickelToggleSectionSwitcher` in
/// `SectionSwitcher.swift`.
extension Notification.Name {
    static let nickelToggleShortcuts = Notification.Name("NickelToggleShortcuts")
}

/// A reference card of the panel's keyboard shortcuts, opened via ⌘/ (and
/// listed in the ⋯ menu). Purely informational — nothing on it is
/// interactive beyond dismissing it — so unlike `SectionSwitcher` it needs no
/// text field or highlighted-row state.
struct ShortcutsOverlay: View {
    @EnvironmentObject private var selection: SelectionModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.15)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                card
                    .frame(width: min(geometry.size.width - 48, 300))
                    .padding(.top, 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 13, weight: .semibold))

            group("Capture", [
                ShortcutRow("Capture selection", ["⇧⇧", "left"]),
                ShortcutRow("Show/hide panel", ["⇧⇧", "right"])
            ])

            group("Navigate", [
                ShortcutRow("Commands, or move to section", ["⌘", "K"]),
                ShortcutRow("Next section", ["⇧", "⌘", "]"]),
                ShortcutRow("Previous section", ["⇧", "⌘", "["]),
                ShortcutRow("Rename section", ["⇧", "⌘", "R"]),
                ShortcutRow("Search", ["⌘", "F"]),
                ShortcutRow("New note", ["⌘", "N"]),
                moveSelectionRow,
                ShortcutRow("Keyboard shortcuts", ["⌘", "/"])
            ])

            group("Window", [
                ShortcutRow("Close panel", ["⌘", "W"]),
                ShortcutRow("Settings", ["⌘", ","])
            ])

            group("Edit", [
                overlayRow(.copy),
                overlayRow(.copyAsList),
                overlayRow(.toggleDone),
                overlayRow(.edit),
                overlayRow(.editInNewWindow),
                overlayRow(.toggleExpanded),
                overlayRow(.merge),
                overlayRow(.delete),
                overlayRow(.moveToLogbook)
            ])
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
    }

    /// One shortcut group: a tiny secondary header followed by its rows.
    private func group(_ title: String, _ rows: [ShortcutRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            ForEach(rows) { row in
                HStack {
                    Text(row.label)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)

                    Spacer()

                    HStack(spacing: 3) {
                        ForEach(row.keys, id: \.self) { key in
                            keyCap(key)
                        }
                    }
                }
            }
        }
    }

    private func keyCap(_ symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary)
            )
    }

    private func dismiss() {
        selection.presentedOverlay = nil
    }

    /// Builds a row from `PanelShortcuts`' table entry for `command`, the
    /// single source of truth these labels and key caps come from — see
    /// `PanelShortcuts.swift`.
    private func overlayRow(_ command: PanelCommand) -> ShortcutRow {
        guard let overlay = PanelShortcuts.shortcut(for: command).overlay else {
            preconditionFailure("no overlay display for \(command)")
        }
        return ShortcutRow(overlay.label, overlay.keys)
    }

    /// The arrows have no single command of their own to display — they're
    /// two table entries (`.moveUp`, `.moveDown`) that share a label — so
    /// this combines both into the one "Move selection" row shown here.
    private var moveSelectionRow: ShortcutRow {
        let up = PanelShortcuts.shortcut(for: .moveUp).overlay!
        let down = PanelShortcuts.shortcut(for: .moveDown).overlay!
        return ShortcutRow(up.label, up.keys + down.keys)
    }
}

/// One row's label and its key caps (rendered one cap per element of `keys`,
/// e.g. `["⌘", "K"]` for ⌘K, or `["⇧⇧", "left"]` for the double-shift capture
/// gesture, which has no single key symbol of its own).
private struct ShortcutRow: Identifiable {
    let label: String
    let keys: [String]
    var id: String { label }

    init(_ label: String, _ keys: [String]) {
        self.label = label
        self.keys = keys
    }
}
