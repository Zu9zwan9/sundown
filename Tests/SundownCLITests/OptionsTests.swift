import XCTest

@testable import SundownCLI

/// The parser decides whether a run may end processes. These tests exist
/// because that decision has no undo, and until now nothing checked it.
final class OptionsTests: XCTestCase {

    // MARK: - The invariant that matters: reports never act

    func testIdleIsAlwaysADryRun() throws {
        XCTAssertTrue(try Options.parse(["--idle"]).dryRun)
    }

    func testSnapshotIsAlwaysADryRun() throws {
        XCTAssertTrue(try Options.parse(["--snapshot"]).dryRun)
    }

    func testCompareIsAlwaysADryRun() throws {
        XCTAssertTrue(try Options.parse(["--compare"]).dryRun)
    }

    /// `--yes` must not talk a reporting flag into acting. If this ever fails,
    /// `sundown --idle --yes` became a kill command.
    func testYesCannotTurnAReportIntoAnAction() throws {
        for flag in ["--idle", "--snapshot", "--compare"] {
            let options = try Options.parse([flag, "--yes"])
            XCTAssertTrue(options.dryRun, "\(flag) --yes must stay a dry run")
        }
    }

    // MARK: - Defaults

    /// A bare invocation must not assume consent. The confirmation prompt is
    /// the only thing between a typo and a SIGKILL.
    func testBareInvocationAssumesNothing() throws {
        let options = try Options.parse([])
        XCTAssertFalse(options.assumeYes)
        XCTAssertFalse(options.dryRun)
    }

    func testDryRunFlags() throws {
        XCTAssertTrue(try Options.parse(["-n"]).dryRun)
        XCTAssertTrue(try Options.parse(["--dry-run"]).dryRun)
    }

    func testYesFlags() throws {
        XCTAssertTrue(try Options.parse(["-y"]).assumeYes)
        XCTAssertTrue(try Options.parse(["--yes"]).assumeYes)
    }

    // MARK: - Rejection, not silent acceptance

    func testUnknownOptionIsRejected() {
        XCTAssertThrowsError(try Options.parse(["--delete-everything"]))
    }

    func testFlagNeedingAValueIsRejectedWithoutOne() {
        XCTAssertThrowsError(try Options.parse(["--grace"]))
        XCTAssertThrowsError(try Options.parse(["--provider"]))
    }

    func testGraceIsRangeChecked() {
        XCTAssertThrowsError(try Options.parse(["--grace", "-1"]))
        XCTAssertThrowsError(try Options.parse(["--grace", "121"]))
        XCTAssertNoThrow(try Options.parse(["--grace", "3"]))
    }

    func testUnknownProviderIsRejected() {
        XCTAssertThrowsError(try Options.parse(["--provider", "not-a-real-provider"]))
    }

    // MARK: - parseSize, because "1.5gb" is the kind of thing that silently rounds

    func testParseSize() {
        XCTAssertEqual(Options.parseSize("1024"), 1024)
        XCTAssertEqual(Options.parseSize("2GB"), 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(Options.parseSize("500MB"), 500 * 1024 * 1024)
        XCTAssertEqual(Options.parseSize("1.5gb"), UInt64(1.5 * 1024 * 1024 * 1024))
        XCTAssertNil(Options.parseSize("banana"))
    }
}

// MARK: - --contribute

extension OptionsTests {

    /// Publishing is a report. If this ever parses as an action, a command whose
    /// job is to print JSON gained the power to end processes.
    func testContributeIsAlwaysADryRun() throws {
        XCTAssertTrue(try Options.parse(["--contribute"]).contribute)
        XCTAssertTrue(try Options.parse(["--contribute"]).dryRun)
        XCTAssertTrue(try Options.parse(["--contribute", "--yes"]).dryRun)
    }

    func testContributeIsOffByDefault() throws {
        XCTAssertFalse(try Options.parse([]).contribute)
    }
}
