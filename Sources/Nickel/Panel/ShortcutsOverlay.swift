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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.overlayScrim(for: colorScheme)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                card
                    .frame(width: min(geometry.size.width - 48, 300))
                    .frame(maxHeight: geometry.size.height - 96)
                    .padding(.top, 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Scrolls when the groups overflow the panel's height; keeps its
    /// intrinsic size (no visible scroll affordance) when they fit — the
    /// default 560pt panel is tall enough for most, but not every, capture
    /// key setting.
    private var card: some View {
        ScrollView {
            cardContent
        }
        .scrollIndicators(.automatic)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 13, weight: .semibold))

            group("Capture", [
                ShortcutRow("Capture selection", [captureKeyGlyph, PanelSettings.captureKey.sideWord]),
                ShortcutRow("Show/hide panel", [panelToggleKeyGlyph, PanelSettings.panelToggleKey.sideWord])
            ])

            group("Navigate", navigateRows)

            group("Window", windowRows(.window))

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

    /// Doubled glyph for the capture key's key cap (the double-tap gesture
    /// has no single key symbol of its own).
    private var captureKeyGlyph: String {
        let glyph = PanelSettings.captureKey.glyph
        return glyph + glyph
    }

    /// Doubled glyph for the panel-toggle key's key cap.
    private var panelToggleKeyGlyph: String {
        let glyph = PanelSettings.panelToggleKey.glyph
        return glyph + glyph
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

    /// Every `WindowShortcuts` entry in `group`, in table order, rendered
    /// from the shared table — see `PanelShortcuts.swift`'s `WindowShortcut`.
    private func windowRows(_ group: WindowShortcutGroup) -> [ShortcutRow] {
        WindowShortcuts.all
            .filter { $0.overlayGroup == group }
            .map { ShortcutRow($0.overlay.label, $0.overlay.keys) }
    }

    /// The Navigate group's rows, with "Move selection" (the arrows — see
    /// `moveSelectionRow`) inserted just before "Keyboard shortcuts", the
    /// table's last Navigate entry, matching the card's original order.
    private var navigateRows: [ShortcutRow] {
        var rows = windowRows(.navigate)
        rows.insert(moveSelectionRow, at: max(rows.count - 1, 0))
        return rows
    }
}

/// One row's label and its key caps (rendered one cap per element of `keys`,
/// e.g. `["⌘", "K"]` for ⌘K, or a doubled modifier glyph plus a side word
/// for the double-tap capture gesture, which has no single key symbol of its
/// own).
private struct ShortcutRow: Identifiable {
    let label: String
    let keys: [String]
    var id: String { label }

    init(_ label: String, _ keys: [String]) {
        self.label = label
        self.keys = keys
    }
}
