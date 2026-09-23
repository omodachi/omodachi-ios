import XCTest
@testable import Omodachi

/// BUILD-2. The stamp is only worth showing if the running app can actually
/// read it back: these assertions run against the host app's own bundle, the
/// same `Bundle.main` the Settings line reads.
final class BuildStampTests: XCTestCase {
    func testTheRunningBundleCarriesACommitAndABuildMinute() {
        let commit = BuildStamp.commit
        XCTAssertFalse(commit.isEmpty)
        XCTAssertTrue(commit.allSatisfy { $0.isHexDigit } || commit == "unknown",
                      "OmodachiBuildCommit is a git short sha, or the unstamped default: \(commit)")

        let version = BuildStamp.version
        XCTAssertEqual(version.count, 12, "CFBundleVersion is yyyymmddHHMM: \(version)")
        XCTAssertTrue(version.allSatisfy(\.isNumber), "CFBundleVersion is digits only: \(version)")
    }

    /// `scripts/build.sh` stamps both, so a build that came from the script
    /// reads back as a real sha and a real minute rather than the defaults.
    func testAStampedBuildReadsBackTheShaAndTheMinuteTheScriptPassed() throws {
        try XCTSkipIf(BuildStamp.commit == "unknown", "Built without scripts/build.sh.")
        XCTAssertGreaterThanOrEqual(BuildStamp.commit.count, 7)
        XCTAssertNotEqual(BuildStamp.version, "000000000000")
        XCTAssertEqual(BuildStamp.summary, Strings.settingsBuildStamp(BuildStamp.commit, BuildStamp.time))
        XCTAssertTrue(BuildStamp.summary.contains(BuildStamp.commit))
    }

    func testTheBuildMinuteIsReadBackAsADateAndATime() {
        // I18N-1: the minute is formatted for the reader's locale rather than
        // written out as `yyyy-mm-dd HH:MM`, so the assertion is against the
        // same formatter rather than against one locale's shape.
        XCTAssertEqual(BuildStamp.readableTime("202609191530"), Format.stamp("202609191530"))
        XCTAssertNotNil(Format.stamp("202609191530"))
        // Anything that is not twelve digits is shown as-is, never mangled.
        XCTAssertEqual(BuildStamp.readableTime("1"), "1")
        XCTAssertEqual(BuildStamp.readableTime("not-a-date!"), "not-a-date!")
    }
}
