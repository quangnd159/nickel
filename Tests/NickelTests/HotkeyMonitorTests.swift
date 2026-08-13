import AppKit
import XCTest
@testable import Nickel

/// Exercises `HotkeyMonitor`'s tap-detection state machine directly via its
/// `internal` `handleFlagsChanged`/`disqualifyCurrentTap` entry points,
/// mirroring the split `SequentialPasteCoordinatorTests` uses: the pure
/// logic is testable headlessly, the real NSEvent taps installed by
/// `start()` are not (see CLAUDE.md's Testing notes).
final class HotkeyMonitorTests: XCTestCase {
    private var firedKeys: [ModifierKey] = []
    private var monitor: HotkeyMonitor!
    private var currentDate = Date(timeIntervalSince1970: 0)

    override func setUp() {
        super.setUp()
        firedKeys = []
        currentDate = Date(timeIntervalSince1970: 0)
        monitor = HotkeyMonitor(now: { [unowned self] in self.currentDate })
        monitor.onDoubleTap = { [weak self] key in self?.firedKeys.append(key) }
    }

    override func tearDown() {
        monitor = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Simulates a clean down/up cycle of `key` with nothing else held,
    /// advancing the clock by `dt` before the down edge.
    private func tap(_ key: ModifierKey, after dt: TimeInterval = 0) {
        currentDate = currentDate.addingTimeInterval(dt)
        monitor.handleFlagsChanged(modifiers: [key.flag], keyCode: key.keyCode)
        monitor.handleFlagsChanged(modifiers: [], keyCode: key.keyCode)
    }

    // MARK: - Basic double-tap

    func testDoubleTapFiresForNonShiftKey() {
        tap(.leftControl)
        tap(.leftControl, after: 0.1)

        XCTAssertEqual(firedKeys, [.leftControl])
    }

    func testDoubleTapFiresForEachOfTheEightKeys() {
        for key in ModifierKey.allCases {
            firedKeys = []
            currentDate = Date(timeIntervalSince1970: 0)
            tap(key)
            tap(key, after: 0.1)
            XCTAssertEqual(firedKeys, [key], "expected \(key) to fire")
        }
    }

    func testMismatchedKeysDoNotFire() {
        tap(.leftShift)
        tap(.rightShift, after: 0.1)

        XCTAssertTrue(firedKeys.isEmpty, "a tap on a different physical key must not complete the sequence")
    }

    func testSecondTapOfDifferentKeyStartsNewSequence() {
        tap(.leftShift)
        tap(.rightShift, after: 0.1)
        // Now a second Right Shift tap within the window of the *second*
        // event (not the first) should fire, since that became tap 1 of a
        // new sequence.
        tap(.rightShift, after: 0.1)

        XCTAssertEqual(firedKeys, [.rightShift])
    }

    // MARK: - Disqualification

    func testSecondModifierJoiningDisqualifies() {
        currentDate = currentDate.addingTimeInterval(0)
        monitor.handleFlagsChanged(modifiers: [.control], keyCode: ModifierKey.leftControl.keyCode)
        // Command joins while Control is still held.
        monitor.handleFlagsChanged(modifiers: [.control, .command], keyCode: ModifierKey.leftCommand.keyCode)
        monitor.handleFlagsChanged(modifiers: [], keyCode: ModifierKey.leftControl.keyCode)

        tap(.leftControl, after: 0.1)

        XCTAssertTrue(firedKeys.isEmpty, "a disqualified first tap must not combine with a later clean tap")
    }

    func testKeyDownDuringHoldDisqualifies() {
        monitor.handleFlagsChanged(modifiers: [.control], keyCode: ModifierKey.leftControl.keyCode)
        monitor.disqualifyCurrentTap() // e.g. a real keyDown observed while Control is held alone
        monitor.handleFlagsChanged(modifiers: [], keyCode: ModifierKey.leftControl.keyCode)

        tap(.leftControl, after: 0.1)

        XCTAssertTrue(firedKeys.isEmpty)
    }

    func testSiblingKeyJoiningDisqualifiesBothShifts() {
        // Left Shift down alone, then Right Shift also goes down (flag stays
        // .shift throughout) before either is released.
        monitor.handleFlagsChanged(modifiers: [.shift], keyCode: ModifierKey.leftShift.keyCode)
        monitor.handleFlagsChanged(modifiers: [.shift], keyCode: ModifierKey.rightShift.keyCode)
        monitor.handleFlagsChanged(modifiers: [], keyCode: ModifierKey.rightShift.keyCode)

        tap(.leftShift, after: 0.1)

        XCTAssertTrue(firedKeys.isEmpty)
    }

    // MARK: - Timing window

    func testSecondTapWithinWindowFires() {
        tap(.leftOption)
        tap(.leftOption, after: HotkeyMonitor.maxTapInterval - 0.01)

        XCTAssertEqual(firedKeys, [.leftOption])
    }

    func testSecondTapAfterWindowExpiryDoesNotFireButStartsNewSequence() {
        tap(.leftOption)
        tap(.leftOption, after: HotkeyMonitor.maxTapInterval + 0.01)

        XCTAssertTrue(firedKeys.isEmpty, "outside the window, the second tap starts a fresh sequence instead")

        tap(.leftOption, after: 0.1)
        XCTAssertEqual(firedKeys, [.leftOption], "the fresh sequence's own second tap should fire")
    }

    // MARK: - ModifierKey mapping

    func testModifierKeyKeyCodeMapping() {
        XCTAssertEqual(ModifierKey(keyCode: 56), .leftShift)
        XCTAssertEqual(ModifierKey(keyCode: 60), .rightShift)
        XCTAssertEqual(ModifierKey(keyCode: 59), .leftControl)
        XCTAssertEqual(ModifierKey(keyCode: 62), .rightControl)
        XCTAssertEqual(ModifierKey(keyCode: 58), .leftOption)
        XCTAssertEqual(ModifierKey(keyCode: 61), .rightOption)
        XCTAssertEqual(ModifierKey(keyCode: 55), .leftCommand)
        XCTAssertEqual(ModifierKey(keyCode: 54), .rightCommand)
        XCTAssertNil(ModifierKey(keyCode: 57)) // Caps Lock
        XCTAssertNil(ModifierKey(keyCode: 63)) // Fn
    }
}
