import XCTest
@testable import Nickel

final class CommandPaletteTests: XCTestCase {

    // MARK: - Match quality

    func testPrefixMatchBeatsWordBoundaryAndSubstring() {
        XCTAssertEqual(PaletteMatcher.quality(of: "Delete Section…", matching: "del"), .prefix)
        XCTAssertEqual(PaletteMatcher.quality(of: "Delete Section…", matching: "sec"), .wordBoundary)
        XCTAssertEqual(PaletteMatcher.quality(of: "Delete Section…", matching: "ect"), .substring)
        XCTAssertNil(PaletteMatcher.quality(of: "Delete Section…", matching: "zzz"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(PaletteMatcher.quality(of: "Clear Done", matching: "CLEAR"), .prefix)
        XCTAssertEqual(PaletteMatcher.quality(of: "clear done", matching: "Done"), .wordBoundary)
    }

    func testEmptyQueryMatchesEverythingAtBestQuality() {
        XCTAssertEqual(PaletteMatcher.quality(of: "Anything", matching: ""), .prefix)
        XCTAssertEqual(PaletteMatcher.quality(of: "Anything", matching: "   "), .prefix)
    }

    func testNoSubsequenceFuzzyMatching() {
        // "cd" would fuzzy-match "Clear Done" letter by letter; it must not.
        XCTAssertNil(PaletteMatcher.quality(of: "Clear Done", matching: "cd"))
        XCTAssertNil(PaletteMatcher.quality(of: "New Section", matching: "ns"))
        XCTAssertNil(PaletteMatcher.quality(of: "Copy All as List", matching: "cal"))
    }

    func testWordStartsFollowNonAlphanumerics() {
        // A word can start after a space, a hyphen, or a slash.
        XCTAssertEqual(PaletteMatcher.quality(of: "Work-Trips", matching: "trip"), .wordBoundary)
        XCTAssertEqual(PaletteMatcher.quality(of: "Home/Errands", matching: "err"), .wordBoundary)
        // Mid-word, so only a substring match.
        XCTAssertEqual(PaletteMatcher.quality(of: "Reading", matching: "eadi"), .substring)
    }

    // MARK: - Ranking

    private struct Row {
        let label: String
        let group: PaletteGroup
    }

    private func rank(_ rows: [Row], query: String) -> [String] {
        PaletteMatcher.ranked(rows, query: query, group: \.group, label: \.label).map(\.label)
    }

    func testRankingOrdersPrefixThenWordBoundaryThenSubstring() {
        let rows = [
            Row(label: "Undone", group: .section),      // substring
            Row(label: "My Done List", group: .section), // word boundary
            Row(label: "Done Today", group: .section)    // prefix
        ]
        XCTAssertEqual(rank(rows, query: "done"), ["Done Today", "My Done List", "Undone"])
    }

    func testRankingKeepsOriginalOrderWithinEqualQuality() {
        let rows = [
            Row(label: "Work", group: .section),
            Row(label: "Wishlist", group: .section),
            Row(label: "Weekly", group: .section)
        ]
        XCTAssertEqual(rank(rows, query: "w"), ["Work", "Wishlist", "Weekly"])
    }

    func testEmptyQueryKeepsEverythingInOrderSectionsFirst() {
        let rows = [
            Row(label: "Clear Done", group: .command),
            Row(label: "Work", group: .section),
            Row(label: "Settings…", group: .command),
            Row(label: "Wishlist", group: .section)
        ]
        XCTAssertEqual(rank(rows, query: ""), ["Work", "Wishlist", "Clear Done", "Settings…"])
    }

    func testSectionsRankAboveCommandsAtEqualQuality() {
        let rows = [
            Row(label: "Delete Section…", group: .command),
            Row(label: "Deliveries", group: .section)
        ]
        XCTAssertEqual(rank(rows, query: "del"), ["Deliveries", "Delete Section…"])
    }

    func testSectionsStayAboveCommandsSoTheGroupsRemainContiguous() {
        // The command matches better than the section, but the destination
        // block still comes first — that's what lets one divider separate
        // them.
        let rows = [
            Row(label: "New Section", group: .command),
            Row(label: "Old News", group: .section)
        ]
        XCTAssertEqual(rank(rows, query: "new"), ["Old News", "New Section"])
    }

    func testRankingDropsNonMatches() {
        let rows = [
            Row(label: "Work", group: .section),
            Row(label: "Settings…", group: .command)
        ]
        XCTAssertEqual(rank(rows, query: "work"), ["Work"])
    }

    // MARK: - Command visibility

    func testMoveModeShowsNoCommandsAtAll() {
        let context = PaletteContext(
            isMoveMode: true,
            activeSection: "Work",
            hasDoneNotesInScope: true,
            hasDoneNotesInActiveSection: true,
            hasNotesInScope: true
        )
        XCTAssertTrue(PaletteCommand.applicable(in: context).isEmpty)
    }

    func testShowAllWithNothingToActOnShowsOnlyTheAlwaysAvailableCommands() {
        let commands = PaletteCommand.applicable(in: PaletteContext())
        XCTAssertEqual(commands, [.newSection, .openLogbook, .settings])
    }

    func testSectionCommandsAppearOnlyWithAnActiveSection() {
        let showAll = PaletteCommand.applicable(in: PaletteContext(hasNotesInScope: true))
        XCTAssertFalse(showAll.contains(.renameSection))
        XCTAssertFalse(showAll.contains(.dissolveSection))
        XCTAssertFalse(showAll.contains(.deleteSection))

        let inSection = PaletteCommand.applicable(in: PaletteContext(activeSection: "Work", hasNotesInScope: true))
        XCTAssertTrue(inSection.contains(.renameSection))
        XCTAssertTrue(inSection.contains(.dissolveSection))
        XCTAssertTrue(inSection.contains(.deleteSection))
    }

    func testClearDoneAppearsOnlyInShowAllWhenThereAreDoneNotes() {
        XCTAssertFalse(PaletteCommand.applicable(in: PaletteContext()).contains(.clearDone))
        XCTAssertTrue(PaletteCommand.applicable(in: PaletteContext(hasDoneNotesInScope: true)).contains(.clearDone))
    }

    func testClearDoneIsHiddenWithAnActiveSectionSoItNeverDuplicatesTheSectionOne() {
        let context = PaletteContext(
            activeSection: "Work",
            hasDoneNotesInScope: true,
            hasDoneNotesInActiveSection: true
        )
        let commands = PaletteCommand.applicable(in: context)
        XCTAssertFalse(commands.contains(.clearDone), "the section-named command covers this case on its own")
        XCTAssertTrue(commands.contains(.clearDoneInSection))
    }

    func testClearDoneInSectionNeedsBothASectionAndDoneNotesInIt() {
        let noSection = PaletteContext(hasDoneNotesInScope: true, hasDoneNotesInActiveSection: true)
        XCTAssertFalse(PaletteCommand.applicable(in: noSection).contains(.clearDoneInSection))

        let sectionWithoutDone = PaletteContext(activeSection: "Work")
        XCTAssertFalse(PaletteCommand.applicable(in: sectionWithoutDone).contains(.clearDoneInSection))

        let sectionWithDone = PaletteContext(
            activeSection: "Work",
            hasDoneNotesInScope: true,
            hasDoneNotesInActiveSection: true
        )
        XCTAssertTrue(PaletteCommand.applicable(in: sectionWithDone).contains(.clearDoneInSection))
    }

    func testCopyAllAsListAppearsOnlyWithNotesInScope() {
        XCTAssertFalse(PaletteCommand.applicable(in: PaletteContext()).contains(.copyAllAsList))
        XCTAssertTrue(PaletteCommand.applicable(in: PaletteContext(hasNotesInScope: true)).contains(.copyAllAsList))
    }

    func testActiveSectionListsEveryCommandExceptTheUnscopedClearDone() {
        let context = PaletteContext(
            activeSection: "Work",
            hasDoneNotesInScope: true,
            hasDoneNotesInActiveSection: true,
            hasNotesInScope: true
        )
        XCTAssertEqual(PaletteCommand.applicable(in: context), [
            .newSection,
            .renameSection,
            .dissolveSection,
            .deleteSection,
            .clearDoneInSection,
            .openLogbook,
            .copyAllAsList,
            .settings
        ])
    }

    func testShowAllListsOnlyTheCommandsThatDontNeedASection() {
        let context = PaletteContext(hasDoneNotesInScope: true, hasNotesInScope: true)
        XCTAssertEqual(PaletteCommand.applicable(in: context), [
            .newSection,
            .clearDone,
            .openLogbook,
            .copyAllAsList,
            .settings
        ])
    }
}
