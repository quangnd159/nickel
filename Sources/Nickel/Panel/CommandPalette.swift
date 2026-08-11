import Foundation

/// How well a candidate label matched the palette's query, best first.
///
/// Deliberately *not* a fuzzy/subsequence match: "cd" must not match
/// "Clear Done". A query only matches where it appears as a literal run of
/// characters, and where that run starts decides the quality.
enum PaletteMatchQuality: Int, Comparable {
    /// The label starts with the query ("del" → "Delete Section…").
    case prefix = 0
    /// A word inside the label starts with the query ("sec" → "New Section").
    case wordBoundary = 1
    /// The query appears somewhere else inside the label ("ect" → "Section").
    case substring = 2

    static func < (lhs: PaletteMatchQuality, rhs: PaletteMatchQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Which half of the palette a row belongs to. Sections (destinations) are
/// always listed before commands, so the two stay contiguous and the divider
/// between them has a single, stable place to sit.
enum PaletteGroup: Int, Comparable {
    case section = 0
    case command = 1

    static func < (lhs: PaletteGroup, rhs: PaletteGroup) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Query matching and ranking for the ⌘K palette. Pure and free of any view
/// or store state, so it can be tested directly.
enum PaletteMatcher {
    /// The best quality at which `query` matches `label`, or `nil` if it
    /// doesn't match at all. An empty (or whitespace-only) query matches
    /// everything at `.prefix`, which leaves the natural order untouched.
    ///
    /// Comparison is case-insensitive and locale-aware.
    static func quality(of label: String, matching query: String) -> PaletteMatchQuality? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .prefix }

        if label.range(of: trimmed, options: [.caseInsensitive, .anchored], range: nil, locale: .current) != nil {
            return .prefix
        }

        for start in wordStarts(of: label) {
            if label.range(
                of: trimmed,
                options: [.caseInsensitive, .anchored],
                range: start..<label.endIndex,
                locale: .current
            ) != nil {
                return .wordBoundary
            }
        }

        if label.range(of: trimmed, options: [.caseInsensitive], range: nil, locale: .current) != nil {
            return .substring
        }

        return nil
    }

    /// Every index in `label` that begins a word: the first character, plus
    /// any character that follows something other than a letter or digit
    /// (space, "…", "-", "/"). The first index is skipped here because a
    /// match there is already a `.prefix` match.
    private static func wordStarts(of label: String) -> [String.Index] {
        var starts: [String.Index] = []
        var previous: Character?
        for index in label.indices {
            let character = label[index]
            if let previous, !previous.isLetter, !previous.isNumber {
                starts.append(index)
            }
            previous = character
        }
        return starts
    }

    /// Filters `items` to those matching `query` and sorts them by, in order:
    /// group (all sections before all commands), match quality, then their
    /// original position. Grouping outranks quality so the section list and
    /// the command list stay contiguous blocks — which is what lets the
    /// palette draw one divider between them — and so a section never falls
    /// below a command.
    static func ranked<Item>(
        _ items: [Item],
        query: String,
        group: (Item) -> PaletteGroup,
        label: (Item) -> String
    ) -> [Item] {
        items.enumerated()
            .compactMap { index, item -> (Int, PaletteGroup, PaletteMatchQuality, Item)? in
                guard let quality = quality(of: label(item), matching: query) else { return nil }
                return (index, group(item), quality, item)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
                return lhs.0 < rhs.0
            }
            .map(\.3)
    }
}

/// One command row in the ⌘K palette's lower half. Commands act on the
/// current active section (where the name says so) or on the whole panel,
/// and mirror items that already exist in the ⋯ menu or a section header's
/// context menu — the palette is a second way to reach them, never a new
/// behavior.
///
/// `allCases` order is the order the palette lists them in for an empty
/// query.
enum PaletteCommand: CaseIterable {
    case newSection
    case renameSection
    case dissolveSection
    case deleteSection
    case clearDone
    case clearDoneInSection
    case openLogbook
    case copyAllAsList
    case settings

    var title: String {
        switch self {
        case .newSection: return "New Section"
        case .renameSection: return "Rename Section"
        case .dissolveSection: return "Dissolve Section"
        case .deleteSection: return "Delete Section…"
        case .clearDone: return "Clear Done"
        case .clearDoneInSection: return "Clear Done in Section"
        case .openLogbook: return "Open Logbook"
        case .copyAllAsList: return "Copy All as List"
        case .settings: return "Settings…"
        }
    }

    /// The leading SF Symbol that marks a row as a command rather than a
    /// destination.
    var symbolName: String {
        switch self {
        case .newSection: return "folder.badge.plus"
        case .renameSection: return "pencil"
        case .dissolveSection: return "folder.badge.minus"
        case .deleteSection: return "trash"
        case .clearDone, .clearDoneInSection: return "checkmark.circle"
        case .openLogbook: return "archivebox"
        case .copyAllAsList: return "list.number"
        case .settings: return "gearshape"
        }
    }
}

/// The panel state a command's applicability depends on, snapshotted so the
/// visibility rules stay a pure function of it.
struct PaletteContext {
    /// The palette in move mode is a pure destination picker: it lists no
    /// commands at all.
    var isMoveMode: Bool
    /// The Logbook lists cleared notes, not a live section's, so every
    /// command that acts on the live list (or that would open the Logbook
    /// again) is out of scope while it's showing.
    var isShowingLogbook: Bool
    var activeSection: String?
    /// Mirrors the ⋯ menu's "Clear Done" enablement: done notes in the
    /// active section, or anywhere when showing all.
    var hasDoneNotesInScope: Bool
    var hasDoneNotesInActiveSection: Bool
    /// Whether "Copy All as List" would copy anything.
    var hasNotesInScope: Bool

    init(
        isMoveMode: Bool = false,
        isShowingLogbook: Bool = false,
        activeSection: String? = nil,
        hasDoneNotesInScope: Bool = false,
        hasDoneNotesInActiveSection: Bool = false,
        hasNotesInScope: Bool = false
    ) {
        self.isMoveMode = isMoveMode
        self.isShowingLogbook = isShowingLogbook
        self.activeSection = activeSection
        self.hasDoneNotesInScope = hasDoneNotesInScope
        self.hasDoneNotesInActiveSection = hasDoneNotesInActiveSection
        self.hasNotesInScope = hasNotesInScope
    }
}

extension PaletteCommand {
    /// Whether this command applies right now. Commands that don't apply are
    /// hidden rather than shown disabled — a palette row you can highlight
    /// but not run is dead weight in a keyboard flow.
    func isApplicable(in context: PaletteContext) -> Bool {
        guard !context.isMoveMode else { return false }
        // In the Logbook only the two commands that still mean something
        // there survive: copying the cleared notes on screen, and Settings.
        // Everything else acts on the live list, and running it from behind
        // the Logbook would change something the user can't see (worst case:
        // "New Section" strands an inline rename on an unrendered header).
        if context.isShowingLogbook {
            switch self {
            case .copyAllAsList: return context.hasNotesInScope
            case .settings: return true
            default: return false
            }
        }
        switch self {
        case .newSection, .openLogbook, .settings:
            return true
        case .renameSection, .dissolveSection, .deleteSection:
            return context.activeSection != nil
        case .clearDone:
            // With a section active, "Clear Done" and "Clear Done in
            // Section" would be the same action twice (the ⋯ menu's Clear
            // Done is already section-scoped), so only the section-named one
            // is listed there.
            return context.activeSection == nil && context.hasDoneNotesInScope
        case .clearDoneInSection:
            return context.activeSection != nil && context.hasDoneNotesInActiveSection
        case .copyAllAsList:
            return context.hasNotesInScope
        }
    }

    /// The commands the palette should list, in order, for `context`.
    static func applicable(in context: PaletteContext) -> [PaletteCommand] {
        allCases.filter { $0.isApplicable(in: context) }
    }
}
