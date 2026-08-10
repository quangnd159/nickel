import XCTest
@testable import Nickel

/// Tests for the composer's "#" section-suggestion popup logic
/// (`ComposerSectionSuggestions`): when it opens, what it lists, how the
/// highlight moves, and when Esc's dismissal re-arms. The popup's anchoring
/// and key interception live in SwiftUI/AppKit and are manual-test territory.
final class ComposerSectionSuggestionsTests: XCTestCase {
    private let sections = ["Errands", "Work Notes", "Reading"]

    // MARK: - Trigger and query extraction

    func testPlainTextIsNotAQuery() {
        XCTAssertNil(ComposerSectionSuggestions.query(in: "buy milk", hasStagedSection: false))
    }

    func testEmptyTextIsNotAQuery() {
        XCTAssertNil(ComposerSectionSuggestions.query(in: "", hasStagedSection: false))
    }

    func testBareHashIsAnEmptyQuery() {
        XCTAssertEqual(ComposerSectionSuggestions.query(in: "#", hasStagedSection: false), "")
    }

    func testHashSpaceIsAnEmptyQuery() {
        XCTAssertEqual(ComposerSectionSuggestions.query(in: "# ", hasStagedSection: false), "")
    }

    func testQueryWithoutASpaceAfterTheHash() {
        XCTAssertEqual(ComposerSectionSuggestions.query(in: "#Err", hasStagedSection: false), "Err")
    }

    func testQueryWithASpaceAfterTheHash() {
        XCTAssertEqual(ComposerSectionSuggestions.query(in: "# Err", hasStagedSection: false), "Err")
    }

    func testQueryKeepsInnerSpaces() {
        XCTAssertEqual(ComposerSectionSuggestions.query(in: "# Work Notes", hasStagedSection: false), "Work Notes")
    }

    func testQueryIsTrimmedAtTheEnd() {
        XCTAssertEqual(ComposerSectionSuggestions.query(in: "#Err  ", hasStagedSection: false), "Err")
    }

    func testMultilineTextIsNeverAQuery() {
        XCTAssertNil(ComposerSectionSuggestions.query(in: "#Errands\nbuy milk", hasStagedSection: false))
    }

    func testHashInTheMiddleIsNotAQuery() {
        XCTAssertNil(ComposerSectionSuggestions.query(in: "buy #milk", hasStagedSection: false))
    }

    func testAStagedChipSuppressesTheQuery() {
        XCTAssertNil(ComposerSectionSuggestions.query(in: "#Err", hasStagedSection: true))
    }

    // MARK: - Rows

    func testEmptyQueryListsEverySectionAndNoCreateRow() {
        XCTAssertEqual(
            ComposerSectionSuggestions.rows(query: "", sections: sections),
            [.existing("Errands"), .existing("Work Notes"), .existing("Reading")]
        )
    }

    func testMatchingQueryRanksSectionsAndAppendsTheCreateRow() {
        XCTAssertEqual(
            ComposerSectionSuggestions.rows(query: "Re", sections: sections),
            [.existing("Reading"), .create("Re")]
        )
    }

    func testWordBoundaryMatchesRankBelowPrefixMatches() {
        XCTAssertEqual(
            ComposerSectionSuggestions.rows(query: "No", sections: ["Work Notes", "Notebook"]),
            [.existing("Notebook"), .existing("Work Notes"), .create("No")]
        )
    }

    func testUnmatchedQueryOffersOnlyTheCreateRow() {
        XCTAssertEqual(
            ComposerSectionSuggestions.rows(query: "Groceries", sections: sections),
            [.create("Groceries")]
        )
    }

    func testExactMatchDropsTheCreateRow() {
        XCTAssertEqual(
            ComposerSectionSuggestions.rows(query: "Errands", sections: sections),
            [.existing("Errands")]
        )
    }

    func testExactMatchIsCaseInsensitive() {
        XCTAssertEqual(
            ComposerSectionSuggestions.rows(query: "errands", sections: sections),
            [.existing("Errands")]
        )
    }

    func testNoSectionsAndAnEmptyQueryHasNothingToSuggest() {
        XCTAssertTrue(ComposerSectionSuggestions.rows(query: "", sections: []).isEmpty)
    }

    func testNoSectionsWithAQueryStillOffersTheCreateRow() {
        XCTAssertEqual(ComposerSectionSuggestions.rows(query: "Work", sections: []), [.create("Work")])
    }

    // MARK: - Visible rows

    func testVisibleRowsAreEmptyForANormalNote() {
        XCTAssertTrue(ComposerSectionSuggestions.visibleRows(
            text: "buy milk",
            hasStagedSection: false,
            sections: sections,
            dismissedQuery: nil
        ).isEmpty)
    }

    func testVisibleRowsAreEmptyWithAChipStaged() {
        XCTAssertTrue(ComposerSectionSuggestions.visibleRows(
            text: "#tag",
            hasStagedSection: true,
            sections: sections,
            dismissedQuery: nil
        ).isEmpty)
    }

    func testVisibleRowsForATypedQuery() {
        XCTAssertEqual(
            ComposerSectionSuggestions.visibleRows(
                text: "#Err",
                hasStagedSection: false,
                sections: sections,
                dismissedQuery: nil
            ),
            [.existing("Errands"), .create("Err")]
        )
    }

    // MARK: - Esc dismissal and re-arm

    func testDismissalHidesTheSameQuery() {
        XCTAssertTrue(ComposerSectionSuggestions.isDismissed(query: "Err", dismissedQuery: "Err"))
    }

    func testDismissalHoldsWhileTheQueryKeepsGrowing() {
        XCTAssertTrue(ComposerSectionSuggestions.isDismissed(query: "Errand list", dismissedQuery: "Err"))
    }

    func testDismissingABareHashKeepsAHashtagTypeable() {
        XCTAssertTrue(ComposerSectionSuggestions.visibleRows(
            text: "#hashtag",
            hasStagedSection: false,
            sections: sections,
            dismissedQuery: ""
        ).isEmpty)
    }

    func testDeletingBackIntoTheDismissedQueryReArms() {
        XCTAssertFalse(ComposerSectionSuggestions.isDismissed(query: "Er", dismissedQuery: "Err"))
        XCTAssertEqual(
            ComposerSectionSuggestions.visibleRows(
                text: "#Er",
                hasStagedSection: false,
                sections: sections,
                dismissedQuery: "Err"
            ),
            [.existing("Errands"), .create("Er")]
        )
    }

    func testDismissalSurvivesWhileTheHashLineIsStillBeingTyped() {
        XCTAssertEqual(
            ComposerSectionSuggestions.dismissalAfterTextChange(
                text: "#hashtag time",
                hasStagedSection: false,
                dismissedQuery: ""
            ),
            ""
        )
    }

    func testDismissalClearsOnceTheTextIsNoLongerAHashQuery() {
        XCTAssertNil(ComposerSectionSuggestions.dismissalAfterTextChange(
            text: "",
            hasStagedSection: false,
            dismissedQuery: "Err"
        ))
        XCTAssertNil(ComposerSectionSuggestions.dismissalAfterTextChange(
            text: "buy milk",
            hasStagedSection: false,
            dismissedQuery: "Err"
        ))
    }

    func testDismissalClearsWhenAChipGetsStaged() {
        XCTAssertNil(ComposerSectionSuggestions.dismissalAfterTextChange(
            text: "#Err",
            hasStagedSection: true,
            dismissedQuery: "Err"
        ))
    }

    func testNothingDismissedShowsThePopup() {
        XCTAssertFalse(ComposerSectionSuggestions.isDismissed(query: "Err", dismissedQuery: nil))
    }

    // MARK: - Highlight movement

    func testHighlightMovesDown() {
        XCTAssertEqual(ComposerSectionSuggestions.movedHighlight(0, by: 1, count: 3), 1)
    }

    func testHighlightWrapsPastTheEnd() {
        XCTAssertEqual(ComposerSectionSuggestions.movedHighlight(2, by: 1, count: 3), 0)
    }

    func testHighlightWrapsPastTheStart() {
        XCTAssertEqual(ComposerSectionSuggestions.movedHighlight(0, by: -1, count: 3), 2)
    }

    func testHighlightWithNoRowsStaysAtZero() {
        XCTAssertEqual(ComposerSectionSuggestions.movedHighlight(0, by: 1, count: 0), 0)
    }

    // MARK: - Acceptance

    func testAcceptingARowStagesItsNameAndEmptiesTheField() {
        var chip = ComposerSectionChip()
        chip.stage(named: ComposerSectionSuggestion.create("Groceries").name)
        XCTAssertEqual(chip.name, "Groceries")
        XCTAssertEqual(ComposerSectionSuggestions.textAfterAcceptance, "")
    }

    func testAcceptedExistingRowStagesTheSectionsOwnSpelling() {
        XCTAssertEqual(ComposerSectionSuggestion.existing("Work Notes").name, "Work Notes")
    }
}
