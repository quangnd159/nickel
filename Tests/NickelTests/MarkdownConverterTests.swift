import AppKit
import XCTest
@testable import Nickel

final class MarkdownConverterTests: XCTestCase {
    // MARK: - HTML path

    private func html(_ body: String) -> Data {
        Data(body.utf8)
    }

    func testHTMLBoldProducesAsteriskWrapping() {
        let result = MarkdownConverter.markdown(fromHTML: html("<b>bold</b>"))
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("**bold**"), "expected **bold** in: \(result!)")
    }

    func testHTMLItalicProducesSingleAsteriskWrapping() {
        let result = MarkdownConverter.markdown(fromHTML: html("<i>italic</i>"))
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("*italic*"), "expected *italic* in: \(result!)")
    }

    func testHTMLLinkProducesMarkdownLink() {
        let result = MarkdownConverter.markdown(fromHTML: html("<a href=\"https://example.com\">link</a>"))
        XCTAssertNotNil(result)
        // AppKit's HTML importer canonicalizes the href via NSURL, which
        // appends a trailing slash to a bare-host URL (this is NSURL
        // normalization, not a MarkdownConverter bug) — assert the actual
        // observed URL rather than the literal href string.
        XCTAssertTrue(result!.contains("[link](https://example.com/)"), "expected markdown link in: \(result!)")
    }

    func testHTMLHeadingBecomesHashPrefixedWithoutBoldMarkers() {
        let result = MarkdownConverter.markdown(fromHTML: html("<h1>Title</h1>"))
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.hasPrefix("# Title"), "expected heading prefix in: \(result!)")
        XCTAssertFalse(result!.contains("**"), "heading text should not carry bold markers: \(result!)")
    }

    func testHTMLUnorderedListProducesHyphenMarkersJoinedTightly() {
        let result = MarkdownConverter.markdown(fromHTML: html("<ul><li>one</li><li>two</li></ul>"))
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("- one\n- two"), "expected tight list join in: \(result!)")
    }

    func testHTMLOrderedListProducesNumberedMarkersJoinedTightly() {
        let result = MarkdownConverter.markdown(fromHTML: html("<ol><li>first</li><li>second</li></ol>"))
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("1. first\n2. second"), "expected tight numbered list join in: \(result!)")
    }

    func testHTMLInlineCodeIsBacktickWrapped() {
        let result = MarkdownConverter.markdown(fromHTML: html("<p>run <code>x = 1</code> now</p>"))
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("`x = 1`"), "expected backtick-wrapped inline code in: \(result!)")
    }

    func testHTMLBlockquoteGetsAngleBracketPrefix() {
        let result = MarkdownConverter.markdown(fromHTML: html("<blockquote>quoted</blockquote>"))
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("> quoted"), "expected blockquote prefix in: \(result!)")
    }

    func testHTMLLiteralAsterisksSurviveUnescaped() {
        let result = MarkdownConverter.markdown(fromHTML: html("<p>two * three</p>"))
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("two * three"), "literal asterisks should not be escaped: \(result!)")
    }

    func testHTMLEmptyInputDoesNotCrash() {
        // Empty HTML: AppKit's importer still succeeds (yielding an
        // effectively-empty attributed string), so the converter returns "".
        let result = MarkdownConverter.markdown(fromHTML: html(""))
        XCTAssertEqual(result, "")
    }

    func testHTMLWhitespaceOnlyInputDoesNotCrash() {
        let result = MarkdownConverter.markdown(fromHTML: html("   \n\t  "))
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    // MARK: - RTF path

    private func rtfData(from attributed: NSAttributedString) -> Data {
        attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])!
    }

    func testRTFMonospacedParagraphBecomesFencedCodeBlock() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let attributed = NSMutableAttributedString(string: "let x = 1", attributes: [.font: font])
        let result = MarkdownConverter.markdown(fromRTF: rtfData(from: attributed))
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("```"), "expected fenced code block in: \(result!)")
        XCTAssertTrue(result!.contains("let x = 1"), "expected code content preserved in: \(result!)")
    }

    func testRTFBoldRunProducesAsteriskWrapping() {
        let baseFont = NSFont.systemFont(ofSize: 13)
        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        let attributed = NSMutableAttributedString(string: "bold text", attributes: [.font: boldFont])
        let result = MarkdownConverter.markdown(fromRTF: rtfData(from: attributed))
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("**bold text**"), "expected bold markers in: \(result!)")
    }
}
