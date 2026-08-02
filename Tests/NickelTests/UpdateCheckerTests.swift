import XCTest
@testable import Nickel

final class UpdateCheckerTests: XCTestCase {
    func testAcceptsGitHubReleaseURL() {
        XCTAssertNotNil(UpdateChecker.validatedReleaseURL("https://github.com/quangnd159/nickel/releases/tag/v1.0.1"))
    }

    func testAcceptsGitHubSubdomain() {
        XCTAssertNotNil(UpdateChecker.validatedReleaseURL("https://api.github.com/repos/quangnd159/nickel"))
    }

    func testRejectsNonHTTPSScheme() {
        XCTAssertNil(UpdateChecker.validatedReleaseURL("http://github.com/quangnd159/nickel/releases/tag/v1.0.1"))
    }

    func testRejectsSpoofedHostWithGitHubInPath() {
        XCTAssertNil(UpdateChecker.validatedReleaseURL("https://evil.example/github.com"))
    }

    func testRejectsHostWithoutDotBoundary() {
        XCTAssertNil(UpdateChecker.validatedReleaseURL("https://notgithub.com/x"))
    }

    func testRejectsFileScheme() {
        XCTAssertNil(UpdateChecker.validatedReleaseURL("file:///etc/hosts"))
    }

    func testRejectsGarbageString() {
        XCTAssertNil(UpdateChecker.validatedReleaseURL("not a url"))
    }
}
