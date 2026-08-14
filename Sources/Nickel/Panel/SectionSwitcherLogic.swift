import Foundation

/// A single row in the palette's result list. `id` is a stable label
/// (rather than an index) so `ForEach` diffs correctly as the query — and
/// therefore the result set — changes on every keystroke. `.showAll` only
/// appears in switch mode, `.noSection` only in move mode — see
/// `SectionSwitcherLogic.results`.
enum Result: Identifiable {
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

/// The action a committed palette row performs, decoupled from how it's
/// executed. Pure mapping from `(Result, move)`; the view executes it.
enum CommitAction {
    case move(to: String?)
    case switchTo(String?)
    case create(String)
    case moveCreate(String)
    case run(PaletteCommand)
}

/// `SectionSwitcher`'s pure logic — candidate building/ranking, the
/// move-mode checkmark computation, and the commit-time result → action
/// mapping — extracted so it can be tested without a running view. The view
/// (`SectionSwitcher.swift`) keeps thin computed-property wrappers that call
/// these with its live `@EnvironmentObject` state; see the doc comments
/// there for the mode semantics (switch vs. move).
enum SectionSwitcherLogic {
    /// Switch mode: "Show All" (if it matches), then every matching section,
    /// then — for a non-empty query that isn't already an exact
    /// (case-insensitive) section name — a trailing "New Section" row.
    ///
    /// Move mode: the same list with "No Section" (ungroup the selection)
    /// standing in for "Show All" — there's no "Show All" destination to
    /// move notes into.
    static func results(sections: [String], move: Bool, query: String, paletteContext: PaletteContext) -> [Result] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        var candidates: [Result] = [move ? .noSection : .showAll]
        candidates += sections.map { .section($0) }
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
        if !trimmedQuery.isEmpty, !sections.contains(where: { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }) {
            let insertionIndex = items.firstIndex { $0.isCommand } ?? items.count
            items.insert(.newSection(trimmedQuery), at: insertionIndex)
        }

        return items
    }

    static func label(for result: Result) -> String {
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
    /// check). `selectedListNames` is the `listName` of every currently
    /// selected note, in any order.
    static func uniformSelectionSection(selectedListNames: [String?]) -> String?? {
        let sections = Set(selectedListNames)
        return sections.count == 1 ? sections.first : nil
    }

    static func isActive(_ result: Result, move: Bool, uniformSelectionSection: String??, activeSection: String?) -> Bool {
        if move {
            guard let uniformSection = uniformSelectionSection else { return false }
            switch result {
            case .section(let name): return uniformSection == name
            case .noSection: return uniformSection == nil
            case .showAll, .newSection, .command: return false
            }
        }
        switch result {
        case .showAll: return activeSection == nil
        case .section(let name): return activeSection == name
        case .noSection, .newSection, .command: return false
        }
    }

    /// Maps a committed row to the action it performs, or `nil` for a
    /// `(Result, move)` combination `results` never actually produces (e.g.
    /// `.noSection` in switch mode) — those are a no-op commit in the view.
    /// The move-mode branch never returns `.switchTo`/`.create`, and the
    /// switch-mode branch never returns `.move`/`.moveCreate` — that split is
    /// the regression net for the accidental-move bug this file's move/switch
    /// split originally fixed.
    static func commitAction(for result: Result, move: Bool) -> CommitAction? {
        if move {
            // Move mode never touches `store.activeSection`:
            // `actions.move(toSection:)` only reassigns `listName` on the
            // already-selected notes (and then clears the selection). That
            // includes the "New Section" row — unlike switch mode's
            // `createSection`, which also activates the new section,
            // `NoteStore.move` already appends an unrecognized name to
            // `sections` on its own, so there's nothing else to do here.
            switch result {
            case .section(let name): return .move(to: name)
            case .noSection: return .move(to: nil)
            case .newSection(let name): return .moveCreate(name)
            case .showAll, .command: return nil // never produced by `results` in move mode
            }
        }
        // Picking any destination leaves the Logbook: it lists cleared
        // notes, not a section's live ones, so switching sections behind it
        // would leave the panel showing something else entirely.
        switch result {
        case .showAll: return .switchTo(nil)
        case .section(let name): return .switchTo(name)
        case .newSection(let name): return .create(name)
        case .command(let command): return .run(command)
        case .noSection: return nil // never produced by `results` in switch mode
        }
    }
}
