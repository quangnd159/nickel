import XCTest
@testable import Nickel

/// Exercises `ModifierKey`'s display accessors (`glyph`, `sideWord`,
/// `sentencePhrase`) used by `ShortcutsOverlay` and `PanelView.emptyState`
/// (plan 029) to derive UI copy from the configured hotkeys instead of
/// hardcoding Shift.
final class ModifierKeyDisplayTests: XCTestCase {
    func testDisplayAccessorsAreConsistentForEveryKey() {
        for key in ModifierKey.allCases {
            XCTAssertFalse(key.glyph.isEmpty, "glyph empty for \(key)")
            XCTAssertFalse(key.sideWord.isEmpty, "sideWord empty for \(key)")
            XCTAssertFalse(key.sentencePhrase.isEmpty, "sentencePhrase empty for \(key)")

            XCTAssertTrue(
                key.displayName.hasPrefix(key.glyph),
                "displayName '\(key.displayName)' doesn't start with glyph '\(key.glyph)' for \(key)"
            )
            XCTAssertTrue(
                key.sentencePhrase.contains(key.sideWord),
                "sentencePhrase '\(key.sentencePhrase)' doesn't contain sideWord '\(key.sideWord)' for \(key)"
            )
        }
    }
}
