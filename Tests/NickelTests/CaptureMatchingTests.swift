import XCTest
@testable import Nickel

final class CaptureMatchingTests: XCTestCase {
    func testExactMatch() {
        XCTAssertTrue(CaptureEngine.pasteboardResultMatchesAXText("hello world", axText: "hello world"))
    }

    func testBoldMarkersAreTolerated() {
        XCTAssertTrue(CaptureEngine.pasteboardResultMatchesAXText("**hello** world", axText: "hello world"))
    }

    func testLinkWithURLIsTolerated() {
        XCTAssertTrue(
            CaptureEngine.pasteboardResultMatchesAXText("[click here](https://example.com)", axText: "click here")
        )
    }

    func testBulletedListMatchesPlainText() {
        XCTAssertTrue(
            CaptureEngine.pasteboardResultMatchesAXText("- one\n- two", axText: "one two")
        )
    }

    func testCompletelyDifferentTextIsRejected() {
        XCTAssertFalse(
            CaptureEngine.pasteboardResultMatchesAXText("**bold statement**", axText: "unrelated selection text")
        )
    }

    func testEmptyAXTextIsRejected() {
        XCTAssertFalse(CaptureEngine.pasteboardResultMatchesAXText("some markdown", axText: ""))
    }

    func testBulletGlyphVersusDashListIsTolerated() {
        let axText = "Hue carries meaning, never state• green = added, struck muted = deleted"
        let markdown = "- Hue carries meaning, never state\n- green = added, struck muted = deleted"
        XCTAssertTrue(CaptureEngine.pasteboardResultMatchesAXText(markdown, axText: axText))
    }

    func testEmDashAndSmartQuoteSubstitutionIsTolerated() {
        let axText = "She said —that\u{2019}s the plan— and left"
        let markdown = "She said --that's the plan-- and left"
        XCTAssertTrue(CaptureEngine.pasteboardResultMatchesAXText(markdown, axText: axText))
    }

    func testDifferentLetterContentIsStillRejected() {
        let axText = "The quick brown fox jumps over the lazy dog"
        let markdown = "- Completely unrelated grocery list items here"
        XCTAssertFalse(CaptureEngine.pasteboardResultMatchesAXText(markdown, axText: axText))
    }
}
