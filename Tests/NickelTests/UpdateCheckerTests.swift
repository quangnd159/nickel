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

    func testCompareDoubleDigitComponents() {
        XCTAssertTrue(UpdateChecker.compareVersions("1.10.0", isNewerThan: "1.2.0"))
    }

    func testCompareEqualWithMissingTrailingComponents() {
        XCTAssertFalse(UpdateChecker.compareVersions("1.2", isNewerThan: "1.2.0"))
        XCTAssertFalse(UpdateChecker.compareVersions("1.2.0", isNewerThan: "1.2"))
    }

    func testComparePreReleaseSuffixKeepsNumericPrefix() {
        XCTAssertTrue(UpdateChecker.compareVersions("1.0.1-beta", isNewerThan: "1.0.0"))
    }

    func testCompareGarbageComponentCountsAsZero() {
        XCTAssertFalse(UpdateChecker.compareVersions("1.x.0", isNewerThan: "1.0.0"))
        XCTAssertFalse(UpdateChecker.compareVersions("1.0.0", isNewerThan: "1.x.0"))
    }

    func testNormalizedVersionStripsVPrefixOnly() {
        XCTAssertEqual(UpdateChecker.normalizedVersion("v1.2.3"), "1.2.3")
        XCTAssertEqual(UpdateChecker.normalizedVersion("1.2.3"), "1.2.3")
        XCTAssertEqual(UpdateChecker.normalizedVersion("version1"), "version1")
    }
}
