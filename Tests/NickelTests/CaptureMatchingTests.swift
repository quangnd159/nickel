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
}
