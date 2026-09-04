import XCTest

@testable import SessionKit

/// The policy decides what gets ended and when. Every one of these tests
/// describes a way it could cost somebody real work.
final class SessionPolicyTests: XCTestCase {

    private let policy = SessionPolicy(runawayCPUPercent: 50)

    private func target(
        id: String = "t",
        provider: Provider = .claudeCode,
        confidence: Confidence = .certain,
        orphaned: Bool = false,
        liveOwner: Bool = false,
        superseded: Bool = false,
        cpu: Double = 0
    ) -> Target {
        Target(
            id: id,
            handle: .process(4821),
            kind: .mcpServer,
            title: "filesystem",
            subtitle: "node · pid 4821",
            evidence: "Declared in Claude Code",
            provider: provider,
            residentBytes: 128 << 20,
            cpuPercent: cpu,
            startedAt: Date(timeIntervalSinceNow: -3600),
            confidence: confidence,
            isOrphaned: orphaned,
            hasLiveOwner: liveOwner,
            isSuperseded: superseded
        )
    }

    // MARK: - The invariant

    /// The reason column exists to explain the checkbox. If a row is not
    /// going to be ended, its reason has to say so — otherwise the user reads
    /// two identical sentences next to two different checkboxes and concludes
    /// the tool is arbitrary.
    ///
    /// Found on a live machine: four superseded MCP servers, three checked and
    /// one not, all printing "Superseded — an identical newer instance is
    /// running". The unchecked one was an uncertain config match, which
    /// teardown excludes.
    func testUnselectedRowsNeverBorrowASelectedRowsExplanation() {
        let policy = SessionPolicy()

        // Every combination that can produce an unchecked row, per phase.
        let candidates = [
            target(id: "a", confidence: .probable, superseded: true),
            target(id: "b", confidence: .probable, orphaned: true),
            target(id: "c", confidence: .probable, orphaned: true, superseded: true),
            target(id: "d", confidence: .certain, liveOwner: true),
            target(id: "e", confidence: .probable),
        ]

        // Phrases that assert a row is being acted on. None may appear on a
        // row the policy declined to select.
        let claimsAction = [
            "Superseded — an identical newer instance is running",
            "Orphaned — its client quit and left it running",
        ]

        for phase in [SessionPolicy.Phase.before, .during, .after] {
            for candidate in candidates {
                let selected =
                    policy.isEligible(candidate, phase: phase)
                    && policy.isPreselected(candidate, phase: phase)
                guard !selected else { continue }

                let text = policy.reason(candidate, phase: phase)
                for claim in claimsAction {
                    XCTAssertNotEqual(
                        text, claim,
                        """
                        Target \(candidate.id) is NOT selected in \(phase), but its \
                        reason reads as though it were: "\(text)"
                        """
                    )
                }
            }
        }
    }

    /// Holds across every phase, with exactly one documented exception below.
    /// If this breaks, the tool eats live sessions and nobody opens it twice.
    func testLiveOwnedIsNeverPreselectedInAnyPhase() {
        let live = target(liveOwner: true)
        for phase in SessionPolicy.Phase.allCases {
            XCTAssertFalse(
                policy.isPreselected(live, phase: phase),
                "\(phase.rawValue) preselected a process with a live owner"
            )
        }
    }

    /// The one exception, and the reason the tool is useful at all.
    ///
    /// Field data: 21 of 37 instrumented health checks found zero orphans
    /// while the machine still ran out of memory — 797 processes, all with
    /// living parents, all duplicates. Orphan-only logic cannot see that.
    /// A superseded target ran an identical command line to a newer sibling,
    /// so the owner is talking to the newer one.
    func testSupersededIsTakenEvenUnderALiveOwner() {
        let staleDuplicate = target(liveOwner: true, superseded: true)
        for phase in SessionPolicy.Phase.allCases {
            XCTAssertTrue(
                policy.isPreselected(staleDuplicate, phase: phase),
                "\(phase.rawValue) missed a duplicate under a live owner"
            )
        }
        XCTAssertTrue(
            policy.reason(staleDuplicate, phase: .during).contains("Superseded")
        )
    }

    /// The exception must not leak into the general case: busy, orphaned, and
    /// uncertain targets under a live owner all stay unchecked.
    func testExceptionIsNarrowlyScopedToSupersession() {
        for candidate in [
            target(liveOwner: true, cpu: 99),
            target(orphaned: true, liveOwner: true),
            target(confidence: .probable, liveOwner: true),
        ] {
            XCTAssertFalse(policy.isPreselected(candidate, phase: .after))
        }
    }

    func testLiveOwnedStaysVisibleSoTheUserCanChooseIt() {
        // Excluding it entirely would be paternalistic; preselecting it would
        // be dangerous. It's shown, unchecked, with a reason.
        let live = target(orphaned: false, liveOwner: true, cpu: 99)
        XCTAssertTrue(policy.isEligible(live, phase: .during))
        XCTAssertFalse(policy.isPreselected(live, phase: .during))
        XCTAssertTrue(policy.reason(live, phase: .during).contains("In use by"))
    }

    // MARK: - Triage narrows, the others don't

    func testDuringOnlyConsidersLeftoversAndRunaways() {
        let ordinary = target()
        let orphan = target(id: "o", orphaned: true)
        let duplicate = target(id: "d", superseded: true)
        let runaway = target(id: "r", cpu: 80)

        XCTAssertFalse(policy.isEligible(ordinary, phase: .during))
        XCTAssertTrue(policy.isEligible(orphan, phase: .during))
        XCTAssertTrue(policy.isEligible(duplicate, phase: .during))
        XCTAssertTrue(policy.isEligible(runaway, phase: .during))

        // …and is still willing to show everything in the other two.
        XCTAssertTrue(policy.isEligible(ordinary, phase: .before))
        XCTAssertTrue(policy.isEligible(ordinary, phase: .after))
    }

    func testDuringChecksLeftoversButNotMerelyBusyProcesses() {
        // Busy is not the same as abandoned, and this is the phase where being
        // wrong costs the most.
        XCTAssertTrue(policy.isPreselected(target(orphaned: true), phase: .during))
        XCTAssertTrue(policy.isPreselected(target(superseded: true), phase: .during))
        XCTAssertFalse(policy.isPreselected(target(cpu: 95), phase: .during))
    }

    // MARK: - Preflight sweeps wider than teardown

    func testPreflightIncludesUncertainMatchesAndTeardownDoesNot() {
        let uncertain = target(confidence: .probable)  // a stray port, say
        XCTAssertTrue(policy.isPreselected(uncertain, phase: .before))
        XCTAssertFalse(policy.isPreselected(uncertain, phase: .after))
    }

    func testTeardownStillChecksCertainMatches() {
        XCTAssertTrue(policy.isPreselected(target(), phase: .after))
    }

    // MARK: - Selection as a whole

    func testSelectionHonoursBothEligibilityAndPreselection() {
        let targets = [
            target(id: "orphan", orphaned: true),
            target(id: "live", liveOwner: true),
            target(id: "ordinary"),
            target(id: "busy", cpu: 90),
        ]

        XCTAssertEqual(policy.selection(from: targets, phase: .during), ["orphan"])
        XCTAssertEqual(
            policy.selection(from: targets, phase: .after),
            ["orphan", "ordinary", "busy"]
        )
    }

    /// The observed failure: ten Claude Desktop servers, six of them older
    /// copies of the four that were just respawned, and none flagged because
    /// none appeared in a config file. Duplicate detection has to work without
    /// a declaration or it doesn't work where it's needed.
    func testSupersededIsIndependentOfConfigMatching() {
        let stale = target(id: "old", superseded: true)
        let fresh = target(id: "new", superseded: false)

        XCTAssertTrue(policy.isEligible(stale, phase: .during))
        XCTAssertFalse(policy.isEligible(fresh, phase: .during))
        XCTAssertTrue(policy.isPreselected(stale, phase: .during))
        XCTAssertTrue(policy.reason(stale, phase: .during).contains("Superseded"))
    }

    func testRunawayThresholdIsConfigurableAndRespected() {
        let strict = SessionPolicy(runawayCPUPercent: 95)
        XCTAssertFalse(strict.isRunaway(target(cpu: 80)))
        XCTAssertTrue(strict.isRunaway(target(cpu: 96)))
    }

    // MARK: - Reasons

    func testEveryReasonIsNonEmptyForEveryPhase() {
        // The reason string is shown on hover and printed by --dry-run. An
        // empty one would mean a row nobody can justify.
        let cases = [
            target(),
            target(orphaned: true),
            target(superseded: true),
            target(liveOwner: true),
            target(cpu: 99),
            target(confidence: .probable),
        ]
        for phase in SessionPolicy.Phase.allCases {
            for candidate in cases {
                XCTAssertFalse(
                    policy.reason(candidate, phase: phase).isEmpty,
                    "empty reason for \(phase.rawValue)"
                )
            }
        }
    }
}

// MARK: - Provider attribution

final class ProviderTests: XCTestCase {

    func testResolvesApplicationBundles() {
        XCTAssertEqual(
            Provider.fromBundlePath("/Applications/Claude.app/Contents/MacOS/Claude"),
            .claudeDesktop
        )
        XCTAssertEqual(
            Provider.fromBundlePath("/Applications/Cursor.app/Contents/MacOS/Cursor"),
            .cursor
        )
    }

    /// The reason attribution matches the `.app` component and not a substring
    /// of the whole path: a project directory must not capture everything
    /// running beneath it.
    func testDoesNotMatchDirectoriesThatMerelyContainTheName() {
        XCTAssertNil(Provider.fromBundlePath("/Users/me/cursor-notes/server.js"))
        XCTAssertNil(Provider.fromBundlePath("/Users/me/claude/scratch/index.js"))
    }

    func testResolvesAgentCLIsByExecutableName() {
        XCTAssertEqual(Provider.fromExecutable("claude"), .claudeCode)
        XCTAssertEqual(Provider.fromExecutable("codex"), .codex)
        XCTAssertEqual(Provider.fromExecutable("cursor-agent"), .cursor)
        XCTAssertNil(Provider.fromExecutable("node"))
    }

    func testResolvesFromConfigClientName() {
        XCTAssertEqual(Provider.named("Claude Desktop"), .claudeDesktop)
        XCTAssertEqual(Provider.named("Windsurf"), .windsurf)
        // An unrecognised client is unattributed, not silently mapped.
        XCTAssertEqual(Provider.named("Some New Tool"), .unattributed)
    }

    func testUnattributedSortsLast() {
        let sorted: [Provider] = [.unattributed, .cursor, .claudeDesktop].sorted()
        XCTAssertEqual(sorted.last, .unattributed)
        XCTAssertEqual(sorted.first, .claudeDesktop)
    }

    func testExtractsBundleName() {
        XCTAssertEqual(
            Provider.appBundleName(
                in: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
            "Visual Studio Code"
        )
        XCTAssertNil(Provider.appBundleName(in: "/usr/local/bin/node"))
    }
}
