import XCTest
@testable import Nickel

/// Covers the pure transition decision behind the Accessibility trust
/// watcher (`AppDelegate.trustTransitionAction`). The watcher itself polls
/// `Permissions.isTrusted`, which needs a real Accessibility grant and can't
/// be driven headlessly — but the (was, now) -> action decision is pure and
/// fully testable.
final class TrustWatcherTests: XCTestCase {
    func testStaysTrustedIsNoTransition() {
        XCTAssertNil(AppDelegate.trustTransitionAction(was: true, now: true))
    }

    func testStaysUntrustedIsNoTransition() {
        XCTAssertNil(AppDelegate.trustTransitionAction(was: false, now: false))
    }

    func testGainingTrustStartsTheMonitor() {
        XCTAssertEqual(AppDelegate.trustTransitionAction(was: false, now: true), .start)
    }

    func testLosingTrustStopsTheMonitor() {
        XCTAssertEqual(AppDelegate.trustTransitionAction(was: true, now: false), .stop)
    }
}
