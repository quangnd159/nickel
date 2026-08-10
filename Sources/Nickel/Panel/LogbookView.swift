import AppKit
import SwiftUI

/// The Logbook: notes that "Clear Done" archived, grouped by the day they
/// were cleared, newest day first. Takes over the panel's content area the
/// way a focused section does, and is read-only — a row can be put back or
/// deleted permanently, nothing else.
struct LogbookView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)

            GeometryReader { geometry in
                ScrollViewReader { scrollProxy in
                ScrollView {
                    ZStack(alignment: .top) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { selection.clear() }

                        if groups.isEmpty {
                            emptyState
                                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        } else {
                            // Plain VStack, like the note list: these are the
                            // same rows under a different heading, and the
                            // list is small enough that laziness buys nothing.
                            // Spacing is a touch wider than the live list's:
                            // flat rows (no card fill) need the extra gap so
                            // adjacent notes don't read as touching.
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(groups, id: \.day) { group in
                                    dayHeader(group.day)
                                        .padding(.top, group.day == groups.first?.day ? 0 : 12)

                                    ForEach(group.notes) { note in
                                        LogbookRow(note: note)
                                    }
                                }

                                footerNote
                                    .padding(.top, 8)
                            }
                            .animation(.noteRowSpring, value: selection.visibleOrder)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .coordinateSpace(name: SelectionModel.viewportSpaceName)
                // Arrow-key navigation keeps the lead row visible, exactly
                // as the note list does.
                .onChange(of: selection.revealRequest) { _, request in
                    guard let request else { return }
                    scrollProxy.scrollTo(request.id)
                }
                }
            }
        }
    }

    // MARK: - Header

    /// A navigation title, not a section label: no trailing hairline (day
    /// groups keep theirs, so the two don't read as siblings), sentence
    /// case, semibold primary text one step up in size from the day-group
    /// labels below.
    private var header: some View {
        LogbookBackButton(action: { selection.setShowingLogbook(false) })
    }

    /// An empty Logbook says one thing, not the same thing twice: the footer
    /// below explains that nothing is purged, which is only worth saying once
    /// there's something in here to keep.
    private var emptyState: some View {
        Text("Cleared notes appear here")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
    }

    /// macOS-Notes-"Recently Deleted"-style footer: explains that the
    /// Logbook doesn't purge itself, since there's no other hint of that
    /// anywhere in the panel. Scrolls with the content, sitting after the
    /// last day group.
    private var footerNote: some View {
        Text("Cleared notes stay here until you delete them.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 8)
    }

    // MARK: - Day grouping

    /// The archived notes (search-filtered, newest-cleared first — see
    /// `SelectionModel.filteredNotes`) split into one group per day cleared.
    /// Built from that same order, so the flat sequence of rows on screen
    /// matches `visibleOrder` exactly and keyboard navigation lines up.
    private var groups: [(day: Date, notes: [Note])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var notesByDay: [Date: [Note]] = [:]
        for note in selection.filteredNotes {
            let day = calendar.startOfDay(for: note.archivedAt ?? note.createdAt)
            if notesByDay[day] == nil { order.append(day) }
            notesByDay[day, default: []].append(note)
        }
        return order.map { (day: $0, notes: notesByDay[$0] ?? []) }
    }

    private func dayHeader(_ day: Date) -> some View {
        HStack(spacing: 8) {
            Text(Self.dayFormatter.string(from: day).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .fixedSize()

            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
    }

    /// "Today"/"Yesterday" where the system provides them, otherwise a
    /// localized date — Foundation's own relative formatting, not a
    /// hand-rolled set of strings.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

/// The Logbook's back navigation: chevron + "Logbook" as one click target,
/// styled as a navigation title rather than a section label — no trailing
/// hairline, sentence case, semibold primary text a step larger than the
/// day-group labels below it. The quiet hover highlight matches the rest of
/// the panel's restraint (no button border, no bold background): a faint
/// fill that only appears under the pointer, the same "hidden until hovered"
/// idea `PanelView`'s composer-chip remove button uses.
private struct LogbookBackButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text("Logbook")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary.opacity(isHovering ? 0.6 : 0))
            )
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        // Pulls the button back flush with the day-group labels below,
        // which have no comparable inset — the hover padding above is
        // inside the click target, not extra outer spacing.
        .padding(.leading, -6)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Logbook, back to notes")
        .help("Back to Notes")
    }
}

/// One Logbook row: the note card's look without any of its editing — the
/// checkbox is a static indicator, double-click does nothing, and the
/// context menu offers only "Put Back" and "Delete Permanently".
private struct LogbookRow: View {
    let note: Note

    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var selection: SelectionModel
    @EnvironmentObject private var actions: PanelActions
    @Environment(\.controlActiveState) private var controlActiveState

    private var isSelected: Bool { selection.selectedIDs.contains(note.id) }

    /// Same emphasized/unemphasized pair `NoteRow` uses, so a Logbook row
    /// selected behind an inactive panel dims like any other list row.
    private var selectionStroke: Color {
        controlActiveState == .key
            ? .accentColor
            : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: note.isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(note.isDone ? .secondary : .quaternary)
                .frame(height: 19)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: note.text.isEmpty ? 0 : 8) {
                if !note.text.isEmpty {
                    // Same dimming vocabulary `NoteRow` uses for a done note
                    // (`.primary` + 0.5 opacity, no strikethrough) — every
                    // Logbook note is settled, so it always reads that way,
                    // not just the ones that happened to be checked off.
                    Text(MarkdownCache.collapsedPreview(for: note.text))
                        .font(.system(size: 14))
                        .lineSpacing(2)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(0.5)
                }

                if !note.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(note.attachments) { attachment in
                            attachmentCard(attachment)
                        }
                    }
                }
            }
        }
        // Same pattern as `NoteRow.noteRowAccessibility`: one combined
        // element, the done state as its value, and the row's two menu items
        // as named actions (hover/right-click reach neither by keyboard).
        .accessibilityElement(children: .combine)
        .accessibilityValue(note.isDone ? "Done" : "Not Done")
        .accessibilityAction(named: Text("Put Back")) { actions.restore(ids: targetIDs) }
        .accessibilityAction(named: Text("Delete Permanently")) { actions.requestPermanentDelete(ids: targetIDs) }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        // Flat, not a card: no fill at all, unlike `NoteRow`'s opaque
        // `.textBackgroundColor` card. The Logbook is a settled record, not
        // another active list, so its rows shouldn't compete with the live
        // list's elevated look — the day headers above carry the structure
        // instead. Selection still reads clearly via the stroke below, the
        // same style `NoteRow` uses.
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selectionStroke, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        )
        .background(RightClickPreSelector { actions.selectOnRightClick(note.id) })
        .contentShape(Rectangle())
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
            let flags = NSEvent.modifierFlags
            selection.handleClick(on: note.id, shift: flags.contains(.shift), command: flags.contains(.command))
        }
        .contextMenu {
            Button("Put Back") { actions.restore(ids: targetIDs) }

            Divider()

            Button("Delete Permanently", role: .destructive) {
                actions.requestPermanentDelete(ids: targetIDs)
            }
        }
        .id(note.id)
    }

    /// The notes a menu item acts on: the whole selection when this row is
    /// part of it (right-clicking an unselected row selects only it first —
    /// see `PanelActions.selectOnRightClick`), otherwise just this row.
    private var targetIDs: Set<UUID> {
        selection.selectedIDs.contains(note.id) ? selection.selectedIDs : [note.id]
    }

    /// The compact icon + filename card `NoteRow` uses for non-image (or
    /// multiple) attachments. The Logbook shows every attachment this way:
    /// its rows are a record, not a place to work with files.
    private func attachmentCard(_ attachment: Attachment) -> some View {
        HStack(spacing: 8) {
            AttachmentThumbnailView(fileURL: store.url(for: attachment, in: note), contentType: attachment.contentType, size: 28)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
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
    }
}
