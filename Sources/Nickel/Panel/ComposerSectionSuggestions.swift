import Foundation

/// One row in the composer's "#" suggestion popup: either an existing
/// section to stage, or the not-yet-created section the typed query would
/// make.
enum ComposerSectionSuggestion: Equatable, Identifiable {
    case existing(String)
    case create(String)

    /// The section name this row stages when accepted. The same either way —
    /// `PanelView.stageSection(named:)` doesn't care whether the section
    /// exists yet (the chip's "New" hint is derived from `store.sections`).
    var name: String {
        switch self {
        case .existing(let name), .create(let name): return name
        }
    }

    /// Stable across keystrokes so `ForEach` diffs the list correctly as the
    /// query — and therefore the row set — changes.
    var id: String {
        switch self {
        case .existing(let name): return "section:\(name)"
        case .create(let name): return "new:\(name)"
        }
    }
}

/// The composer's "#" section-suggestion popup, as pure functions of the
/// composer's text, the staged chip, the known sections, and what the user
/// last dismissed with Esc. `PanelView` keeps only two pieces of `@State`
/// (the dismissed query and the highlighted index) and derives the rows from
/// these on every render, so there's no popup state to keep in sync.
enum ComposerSectionSuggestions {
    /// The section query the composer's text is asking for, or `nil` when
    /// the text isn't a "#" query at all.
    ///
    /// A query is a single line starting with "#", with or without a space
    /// after it; the rest, trimmed, is the query ("" for a bare "#"). Text
    /// with a newline in it is always a normal note, and so is anything typed
    /// while a section chip is already staged — one destination at a time,
    /// and "#tag" has to stay typeable once the destination is settled.
    static func query(in text: String, hasStagedSection: Bool) -> String? {
        guard !hasStagedSection, !text.contains("\n"), text.hasPrefix("#") else { return nil }
        var rest = text.dropFirst()
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a popup for `query` should stay closed because Esc dismissed
    /// it at `dismissedQuery`.
    ///
    /// Dismissal sticks while the user keeps *extending* what they dismissed:
    /// pressing Esc at "#" and then typing "hashtag" leaves the popup closed,
    /// which is the whole point of Esc (a "#hashtag" note stays typeable).
    /// Deleting back or editing what was dismissed re-arms it, since that's
    /// the user reworking the "#…" prefix rather than typing past it.
    static func isDismissed(query: String, dismissedQuery: String?) -> Bool {
        guard let dismissedQuery else { return false }
        return query.hasPrefix(dismissedQuery)
    }

    /// The dismissal to keep after the composer's text changes: cleared once
    /// the text isn't a "#" query at all any more (the line was erased,
    /// rewritten as a normal note, or a chip got staged), so the next "#"
    /// starts fresh rather than inheriting an old Esc.
    static func dismissalAfterTextChange(
        text: String,
        hasStagedSection: Bool,
        dismissedQuery: String?
    ) -> String? {
        query(in: text, hasStagedSection: hasStagedSection) == nil ? nil : dismissedQuery
    }

    /// Every existing section matching `query` (ranked by `PaletteMatcher`,
    /// all of them for an empty query), followed by a "New Section" row when
    /// the query is non-empty and isn't already a section's name.
    static func rows(query: String, sections: [String]) -> [ComposerSectionSuggestion] {
        var rows = PaletteMatcher.ranked(
            sections,
            query: query,
            group: { _ in .section },
            label: { $0 }
        ).map { ComposerSectionSuggestion.existing($0) }

        if !query.isEmpty, !sections.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) {
            rows.append(.create(query))
        }
        return rows
    }

    /// The rows to show right now — empty when the popup shouldn't be open at
    /// all (the composer doesn't have focus, no "#" query, dismissed with Esc,
    /// or nothing to suggest).
    ///
    /// `isComposerFocused` is what every native completion list does: the
    /// popup belongs to the field, so it goes away the moment the field stops
    /// being the focused control — clicking the note list, or the panel
    /// ceasing to be the key window. The caller folds the window's key state
    /// into this flag.
    static func visibleRows(
        text: String,
        isComposerFocused: Bool,
        hasStagedSection: Bool,
        sections: [String],
        dismissedQuery: String?
    ) -> [ComposerSectionSuggestion] {
        guard isComposerFocused,
              let query = query(in: text, hasStagedSection: hasStagedSection),
              !isDismissed(query: query, dismissedQuery: dismissedQuery) else { return [] }
        return rows(query: query, sections: sections)
    }

    /// The highlighted row after moving `direction` steps (↓ = +1, ↑ = -1),
    /// wrapping at both ends.
    static func movedHighlight(_ index: Int, by direction: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + direction) % count + count) % count
    }

    /// The composer's text after a suggestion is accepted: empty, because the
    /// whole "#…" line becomes the chip and the field is left ready for the
    /// note's body.
    static let textAfterAcceptance = ""
}
