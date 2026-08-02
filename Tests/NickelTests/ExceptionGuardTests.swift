import XCTest
import NickelObjCShims

final class ExceptionGuardTests: XCTestCase {
    func testCompletedBlockReturnsTrue() {
        var ran = false
        let result = NKRunWithExceptionGuard { ran = true }
        XCTAssertTrue(result)
        XCTAssertTrue(ran)
    }

    func testThrownNSExceptionIsCaughtAndReturnsFalse() {
        let result = NKRunWithExceptionGuard {
            NSException(name: .genericException, reason: "test", userInfo: nil).raise()
        }
        XCTAssertFalse(result)
    }
}
