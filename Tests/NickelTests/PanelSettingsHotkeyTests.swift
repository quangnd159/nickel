import XCTest
@testable import Nickel

/// Covers the capture/panel-toggle key settings added to `PanelSettings`:
/// defaults, unknown-value fallback, and the swap-on-conflict rule that
/// keeps the two actions from ever sharing a key.
final class PanelSettingsHotkeyTests: XCTestCase {
    private let captureKeyDefaultsKey = "captureModifierKey"
    private let panelToggleKeyDefaultsKey = "panelToggleModifierKey"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: captureKeyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: panelToggleKeyDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: captureKeyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: panelToggleKeyDefaultsKey)
        super.tearDown()
    }

    func testDefaultsWhenNothingStored() {
        XCTAssertEqual(PanelSettings.captureKey, .leftShift)
        XCTAssertEqual(PanelSettings.panelToggleKey, .rightShift)
    }

    func testUnknownStoredRawValueFallsBackToDefault() {
        UserDefaults.standard.set("notAKey", forKey: captureKeyDefaultsKey)
        UserDefaults.standard.set("alsoNotAKey", forKey: panelToggleKeyDefaultsKey)

        XCTAssertEqual(PanelSettings.captureKey, .leftShift)
        XCTAssertEqual(PanelSettings.panelToggleKey, .rightShift)
    }

    func testSettingCaptureKeyToUnusedKeyDoesNotAffectPanelToggleKey() {
        PanelSettings.captureKey = .leftControl

        XCTAssertEqual(PanelSettings.captureKey, .leftControl)
        XCTAssertEqual(PanelSettings.panelToggleKey, .rightShift)
    }

    func testSettingCaptureKeyToPanelToggleKeySwapsThem() {
        // Defaults: capture = leftShift, toggle = rightShift.
        PanelSettings.captureKey = .rightShift

        XCTAssertEqual(PanelSettings.captureKey, .rightShift)
        XCTAssertEqual(PanelSettings.panelToggleKey, .leftShift, "the displaced key moves to the other action, like System Settings conflict resolution")
    }

    func testSettingPanelToggleKeyToCaptureKeySwapsThem() {
        PanelSettings.panelToggleKey = .leftShift

        XCTAssertEqual(PanelSettings.panelToggleKey, .leftShift)
        XCTAssertEqual(PanelSettings.captureKey, .rightShift)
    }

    func testSwapPostsBothChangeNotifications() {
        var captureChanged = false
        var toggleChanged = false
        let captureObserver = NotificationCenter.default.addObserver(
            forName: PanelSettings.captureKeyDidChange, object: nil, queue: nil
        ) { _ in captureChanged = true }
        let toggleObserver = NotificationCenter.default.addObserver(
            forName: PanelSettings.panelToggleKeyDidChange, object: nil, queue: nil
        ) { _ in toggleChanged = true }
        defer {
            NotificationCenter.default.removeObserver(captureObserver)
            NotificationCenter.default.removeObserver(toggleObserver)
        }

        PanelSettings.captureKey = .rightShift // conflicts with the default toggle key

        XCTAssertTrue(captureChanged)
        XCTAssertTrue(toggleChanged)
    }

    func testTwoSettingsAreNeverEqualAcrossArbitraryAssignments() {
        for key in ModifierKey.allCases {
            PanelSettings.captureKey = key
            XCTAssertNotEqual(PanelSettings.captureKey, PanelSettings.panelToggleKey)

            PanelSettings.panelToggleKey = key
            XCTAssertNotEqual(PanelSettings.captureKey, PanelSettings.panelToggleKey)
        }
    }
}
