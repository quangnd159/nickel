import XCTest
@testable import Nickel

final class NoteEditorTitleTests: XCTestCase {
    func testUsesFirstLine() {
        XCTAssertEqual(NoteEditorTitle.title(for: "Buy milk\nand eggs"), "Buy milk")
    }

    func testStripsHeadingMarker() {
        XCTAssertEqual(NoteEditorTitle.title(for: "# Meeting notes\n\nagenda"), "Meeting notes")
    }

    func testStripsListMarker() {
        XCTAssertEqual(NoteEditorTitle.title(for: "- Buy milk\n- Buy eggs"), "Buy milk")
    }

    func testStripsBlockquoteMarker() {
        XCTAssertEqual(NoteEditorTitle.title(for: "> Quoted line"), "Quoted line")
    }

    func testStripsInlineStyling() {
        XCTAssertEqual(NoteEditorTitle.title(for: "**Ship** the `build`"), "Ship the build")
    }

    func testSkipsLeadingBlankLines() {
        XCTAssertEqual(NoteEditorTitle.title(for: "\n\n   \nReal title"), "Real title")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(NoteEditorTitle.title(for: "   Padded title   \nbody"), "Padded title")
    }

    func testEmptyNoteFallsBackToPlaceholder() {
        XCTAssertEqual(NoteEditorTitle.title(for: ""), "New Note")
    }

    func testWhitespaceOnlyNoteFallsBackToPlaceholder() {
        XCTAssertEqual(NoteEditorTitle.title(for: "  \n\t\n"), "New Note")
    }
}
