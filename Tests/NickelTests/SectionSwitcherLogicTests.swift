import XCTest
@testable import Nickel

final class SectionSwitcherLogicTests: XCTestCase {

    // MARK: - results: switch mode

    func testSwitchModeFirstRowIsShowAll() {
        let items = SectionSwitcherLogic.results(sections: ["Work", "Home"], move: false, query: "", paletteContext: PaletteContext())
        XCTAssertEqual(items.first?.id, "show-all")
    }

    func testSwitchModeSectionsAreRankedByQuery() {
        let items = SectionSwitcherLogic.results(sections: ["Wishlist", "Work"], move: false, query: "wor", paletteContext: PaletteContext())
        // "Show All" doesn't match "wor" at all, so it's filtered out; "Work"
        // is a prefix match and outranks "Wishlist"'s substring match. The
        // query isn't an exact (case-insensitive) match for any section, so
        // a trailing "New Section" row follows.
        XCTAssertEqual(items.map(\.id), ["section:Work", "new:wor"])
    }

    func testSwitchModeNewSectionAppearsOnlyForNonMatchingNonEmptyQuery() {
        let matching = SectionSwitcherLogic.results(sections: ["Work"], move: false, query: "Work", paletteContext: PaletteContext())
        XCTAssertFalse(matching.contains { if case .newSection = $0 { return true }; return false })

        let nonMatching = SectionSwitcherLogic.results(sections: ["Work"], move: false, query: "Errands", paletteContext: PaletteContext())
        XCTAssertTrue(nonMatching.contains { if case .newSection(let name) = $0 { return name == "Errands" }; return false })

        let empty = SectionSwitcherLogic.results(sections: ["Work"], move: false, query: "", paletteContext: PaletteContext())
        XCTAssertFalse(empty.contains { if case .newSection = $0 { return true }; return false })
    }

    func testSwitchModeNewSectionMatchIsCaseInsensitive() {
        let items = SectionSwitcherLogic.results(sections: ["Work"], move: false, query: "WORK", paletteContext: PaletteContext())
        XCTAssertFalse(items.contains { if case .newSection = $0 { return true }; return false })
    }

    func testSwitchModeCommandsAppearOnlyInSwitchMode() {
        let context = PaletteContext(activeSection: nil, hasDoneNotesInScope: true, hasNotesInScope: true)
        let switchItems = SectionSwitcherLogic.results(sections: [], move: false, query: "", paletteContext: context)
        XCTAssertTrue(switchItems.contains { $0.isCommand })

        let moveContext = PaletteContext(isMoveMode: true, activeSection: nil, hasDoneNotesInScope: true, hasNotesInScope: true)
        let moveItems = SectionSwitcherLogic.results(sections: [], move: true, query: "", paletteContext: moveContext)
        XCTAssertFalse(moveItems.contains { $0.isCommand })
    }

    func testSwitchModeCommandsFollowASingleHairlineAfterDestinations() {
        // Regression for the "New Section" row's insertion point: it belongs
        // above the command block, not after it.
        let context = PaletteContext(activeSection: nil, hasDoneNotesInScope: true, hasNotesInScope: true)
        let items = SectionSwitcherLogic.results(sections: ["Work"], move: false, query: "e", paletteContext: context)
        let firstCommandIndex = items.firstIndex { $0.isCommand }
        let newSectionIndex = items.firstIndex { if case .newSection = $0 { return true }; return false }
        if let firstCommandIndex, let newSectionIndex {
            XCTAssertLessThan(newSectionIndex, firstCommandIndex, "New Section must sit above the command block")
        }
    }

    // MARK: - results: move mode

    func testMoveModeFirstRowIsNoSection() {
        let items = SectionSwitcherLogic.results(sections: ["Work"], move: true, query: "", paletteContext: PaletteContext(isMoveMode: true))
        XCTAssertEqual(items.first?.id, "no-section")
    }

    func testMoveModeNeverListsCommandRows() {
        let context = PaletteContext(isMoveMode: true, activeSection: "Work", hasDoneNotesInScope: true, hasDoneNotesInActiveSection: true, hasNotesInScope: true)
        let items = SectionSwitcherLogic.results(sections: ["Work"], move: true, query: "", paletteContext: context)
        XCTAssertTrue(items.allSatisfy { !$0.isCommand })
    }

    func testMoveModeStillOffersNewSectionForANonMatchingQuery() {
        let items = SectionSwitcherLogic.results(sections: ["Work"], move: true, query: "Personal", paletteContext: PaletteContext(isMoveMode: true))
        XCTAssertTrue(items.contains { if case .newSection(let name) = $0 { return name == "Personal" }; return false })
    }

    // MARK: - uniformSelectionSection

    func testUniformSelectionSectionForAUniformNamedSection() {
        XCTAssertEqual(SectionSwitcherLogic.uniformSelectionSection(selectedListNames: ["Work", "Work"]), .some(.some("Work")))
    }

    func testUniformSelectionSectionForAUniformUngroupedSelection() {
        XCTAssertEqual(SectionSwitcherLogic.uniformSelectionSection(selectedListNames: [nil, nil]), .some(.none))
    }

    func testUniformSelectionSectionForAMixedSelectionIsNil() {
        XCTAssertNil(SectionSwitcherLogic.uniformSelectionSection(selectedListNames: ["Work", "Home"]))
    }

    func testUniformSelectionSectionForAMixedGroupedAndUngroupedSelectionIsNil() {
        XCTAssertNil(SectionSwitcherLogic.uniformSelectionSection(selectedListNames: ["Work", nil]))
    }

    func testUniformSelectionSectionForAnEmptySelectionIsNil() {
        XCTAssertNil(SectionSwitcherLogic.uniformSelectionSection(selectedListNames: []))
    }

    // MARK: - isActive

    func testIsActiveInMoveModeChecksTheUniformSection() {
        XCTAssertTrue(SectionSwitcherLogic.isActive(.section("Work"), move: true, uniformSelectionSection: .some(.some("Work")), activeSection: nil))
        XCTAssertFalse(SectionSwitcherLogic.isActive(.section("Home"), move: true, uniformSelectionSection: .some(.some("Work")), activeSection: nil))
    }

    func testIsActiveInMoveModeChecksNoSectionForAnUngroupedUniformSelection() {
        XCTAssertTrue(SectionSwitcherLogic.isActive(.noSection, move: true, uniformSelectionSection: .some(.none), activeSection: nil))
        XCTAssertFalse(SectionSwitcherLogic.isActive(.noSection, move: true, uniformSelectionSection: .some(.some("Work")), activeSection: nil))
    }

    func testIsActiveInMoveModeIsFalseWithNoUniformSection() {
        XCTAssertFalse(SectionSwitcherLogic.isActive(.section("Work"), move: true, uniformSelectionSection: nil, activeSection: nil))
        XCTAssertFalse(SectionSwitcherLogic.isActive(.noSection, move: true, uniformSelectionSection: nil, activeSection: nil))
    }

    func testIsActiveInSwitchModeFollowsActiveSection() {
        XCTAssertTrue(SectionSwitcherLogic.isActive(.showAll, move: false, uniformSelectionSection: nil, activeSection: nil))
        XCTAssertFalse(SectionSwitcherLogic.isActive(.showAll, move: false, uniformSelectionSection: nil, activeSection: "Work"))
        XCTAssertTrue(SectionSwitcherLogic.isActive(.section("Work"), move: false, uniformSelectionSection: nil, activeSection: "Work"))
        XCTAssertFalse(SectionSwitcherLogic.isActive(.section("Home"), move: false, uniformSelectionSection: nil, activeSection: "Work"))
    }

    func testNewSectionRowIsNeverActiveInEitherMode() {
        XCTAssertFalse(SectionSwitcherLogic.isActive(.newSection("X"), move: true, uniformSelectionSection: .some(.some("X")), activeSection: nil))
        XCTAssertFalse(SectionSwitcherLogic.isActive(.newSection("X"), move: false, uniformSelectionSection: nil, activeSection: "X"))
    }

    // MARK: - commitAction

    func testCommitActionForSectionRowInMoveModeIsMove() {
        guard case .move(let name) = SectionSwitcherLogic.commitAction(for: .section("Work"), move: true) else {
            return XCTFail("expected .move")
        }
        XCTAssertEqual(name, "Work")
    }

    func testCommitActionForNoSectionInMoveModeIsMoveToNil() {
        guard case .move(let name) = SectionSwitcherLogic.commitAction(for: .noSection, move: true) else {
            return XCTFail("expected .move")
        }
        XCTAssertNil(name)
    }

    func testCommitActionForNewSectionInMoveModeIsMoveCreate() {
        guard case .moveCreate(let name) = SectionSwitcherLogic.commitAction(for: .newSection("Errands"), move: true) else {
            return XCTFail("expected .moveCreate")
        }
        XCTAssertEqual(name, "Errands")
    }

    func testCommitActionForShowAllAndCommandInMoveModeIsNil() {
        XCTAssertNil(SectionSwitcherLogic.commitAction(for: .showAll, move: true))
        XCTAssertNil(SectionSwitcherLogic.commitAction(for: .command(.settings), move: true))
    }

    func testCommitActionForShowAllInSwitchModeIsSwitchToNil() {
        guard case .switchTo(let name) = SectionSwitcherLogic.commitAction(for: .showAll, move: false) else {
            return XCTFail("expected .switchTo")
        }
        XCTAssertNil(name)
    }

    func testCommitActionForSectionInSwitchModeIsSwitchTo() {
        guard case .switchTo(let name) = SectionSwitcherLogic.commitAction(for: .section("Work"), move: false) else {
            return XCTFail("expected .switchTo")
        }
        XCTAssertEqual(name, "Work")
    }

    func testCommitActionForNewSectionInSwitchModeIsCreate() {
        guard case .create(let name) = SectionSwitcherLogic.commitAction(for: .newSection("Errands"), move: false) else {
            return XCTFail("expected .create")
        }
        XCTAssertEqual(name, "Errands")
    }

    func testCommitActionForCommandInSwitchModeIsRun() {
        guard case .run(let command) = SectionSwitcherLogic.commitAction(for: .command(.settings), move: false) else {
            return XCTFail("expected .run")
        }
        XCTAssertEqual(command, .settings)
    }

    func testCommitActionForNoSectionInSwitchModeIsNil() {
        XCTAssertNil(SectionSwitcherLogic.commitAction(for: .noSection, move: false))
    }

    /// The accidental-move regression pin: switch mode (⌘K) must never yield
    /// a `.move`/`.moveCreate` action for any row `results` can produce there
    /// — that's exactly the bug class the move/switch split fixed.
    func testSwitchModeNeverYieldsAMoveAction() {
        let allRows: [Result] = [.showAll, .section("Work"), .noSection, .newSection("New"), .command(.settings)]
        for row in allRows {
            switch SectionSwitcherLogic.commitAction(for: row, move: false) {
            case .move, .moveCreate:
                XCTFail("switch mode produced a move action for \(row)")
            default:
                break
            }
        }
    }

    /// The mirror image: move mode (⌃⌘M) must never yield a `.switchTo`,
    /// `.create`, or `.run` action.
    func testMoveModeNeverYieldsASwitchOrCommandAction() {
        let allRows: [Result] = [.showAll, .section("Work"), .noSection, .newSection("New"), .command(.settings)]
        for row in allRows {
            switch SectionSwitcherLogic.commitAction(for: row, move: true) {
            case .switchTo, .create, .run:
                XCTFail("move mode produced a switch/command action for \(row)")
            default:
                break
            }
        }
    }
}
