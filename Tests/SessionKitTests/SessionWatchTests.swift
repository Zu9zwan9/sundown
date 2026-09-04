import XCTest

@testable import SessionKit

/// This detector wakes a notification that offers to kill processes. Almost
/// every test here is about the cases where it must stay quiet.
final class SessionWatchTests: XCTestCase {

    private func agent(
        pid: Int32, provider: String = "claude-code", started: TimeInterval = -3600
    ) -> SessionWatch.SeenAgent {
        SessionWatch.SeenAgent(
            pid: pid,
            providerID: provider,
            title: "claude",
            startedAt: Date(timeIntervalSinceNow: started)
        )
    }

    private func leftover(
        id: String = "l1", provider: Provider = .claudeCode, bytes: UInt64 = 128 << 20
    ) -> Target {
        Target(
            id: id,
            handle: .process(9001),
            kind: .mcpServer,
            title: "filesystem",
            subtitle: "node · pid 9001",
            evidence: "Declared in Claude Code",
            provider: provider,
            residentBytes: bytes,
            cpuPercent: 0,
            startedAt: Date(timeIntervalSinceNow: -3600),
            confidence: .certain,
            isOrphaned: true,
            hasLiveOwner: false,
            isSuperseded: false
        )
    }

    // MARK: - When it fires

    func testAnAgentThatVanishedLeavingLeftoversFires() {
        let event = SessionWatch.detect(
            previous: SessionWatch(agents: [agent(pid: 100)]),
            currentAgents: [],
            leftovers: [leftover()]
        )
        let unwrapped = try? XCTUnwrap(event)
        XCTAssertNotNil(unwrapped)
        XCTAssertEqual(event?.endedAgents.count, 1)
        XCTAssertEqual(event?.leftovers.count, 1)
        XCTAssertTrue(event?.headline.contains("Claude Code") == true)
    }

    /// Only the ended agent's leftovers. Another provider's servers are still
    /// in use by a session that hasn't ended.
    func testOnlyTheEndedProvidersLeftoversAreIncluded() {
        let event = SessionWatch.detect(
            previous: SessionWatch(agents: [agent(pid: 100, provider: "claude-code")]),
            currentAgents: [agent(pid: 200, provider: "cursor")],
            leftovers: [
                leftover(id: "mine", provider: .claudeCode),
                leftover(id: "theirs", provider: .cursor),
            ]
        )
        XCTAssertEqual(event?.leftovers.map(\.id), ["mine"])
    }

    // MARK: - When it must not

    /// The worst possible first impression: install the tool, and it
    /// immediately claims every agent you aren't running just ended.
    func testFirstRunNeverFires() {
        let event = SessionWatch.detect(
            previous: nil,
            currentAgents: [],
            leftovers: [leftover()]
        )
        XCTAssertNil(event)
    }

    func testNothingEndedMeansSilence() {
        let event = SessionWatch.detect(
            previous: SessionWatch(agents: [agent(pid: 100)]),
            currentAgents: [agent(pid: 100)],
            leftovers: [leftover()]
        )
        XCTAssertNil(event)
    }

    /// A clean exit that reaped its own children is a success, not news. This
    /// is the case that decides whether the tool is tolerable on a timer.
    func testAnAgentThatLeftNothingBehindIsNotWorthMentioning() {
        let event = SessionWatch.detect(
            previous: SessionWatch(agents: [agent(pid: 100)]),
            currentAgents: [],
            leftovers: []
        )
        XCTAssertNil(event)
    }

    /// Leftovers exist, but from a provider whose agent is still running.
    func testLeftoversFromAStillRunningAgentDoNotFire() {
        let event = SessionWatch.detect(
            previous: SessionWatch(agents: [
                agent(pid: 100, provider: "claude-code"),
                agent(pid: 200, provider: "cursor"),
            ]),
            currentAgents: [agent(pid: 100, provider: "claude-code")],
            leftovers: [leftover(provider: .claudeCode)]  // belongs to the survivor
        )
        XCTAssertNil(event)
    }

    // MARK: - PID reuse

    /// macOS recycles PIDs. Matching on the number alone means a fresh,
    /// unrelated process wearing a dead agent's PID reads as "still running",
    /// and the session end is never reported — silently, and worst on the
    /// machines that churn processes hardest.
    func testSamePidWithADifferentStartTimeIsADifferentProcess() {
        let before = agent(pid: 100, started: -7200)
        let recycled = agent(pid: 100, started: -5)

        XCTAssertFalse(before.isSameProcess(as: recycled))

        let event = SessionWatch.detect(
            previous: SessionWatch(agents: [before]),
            currentAgents: [recycled],
            leftovers: [leftover()]
        )
        XCTAssertNotNil(event, "PID reuse hid a session that really did end")
    }

    /// Start times round-trip through JSON and come from the kernel, so they
    /// are compared with tolerance rather than for equality.
    func testStartTimesAreComparedWithTolerance() {
        let a = SessionWatch.SeenAgent(
            pid: 1, providerID: "x", title: "t", startedAt: Date(timeIntervalSince1970: 1_000.000))
        let b = SessionWatch.SeenAgent(
            pid: 1, providerID: "x", title: "t", startedAt: Date(timeIntervalSince1970: 1_000.4))
        XCTAssertTrue(a.isSameProcess(as: b))

        let far = SessionWatch.SeenAgent(
            pid: 1, providerID: "x", title: "t", startedAt: Date(timeIntervalSince1970: 1_010))
        XCTAssertFalse(a.isSameProcess(as: far))
    }

    // MARK: - Who counts as an agent

    private func process(_ pid: pid_t, _ argv0: String, name: String) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid,
            parentPID: 1,
            userID: 501,
            name: name,
            arguments: [argv0],
            startedAt: Date(timeIntervalSinceNow: -600),
            residentBytes: 64 << 20,
            cpuNanoseconds: 0
        )
    }

    /// Electron apps run dozens of helper processes and recycle them
    /// constantly. Counting them as agents meant a "session finished" report
    /// every few minutes — 54 tracked processes on a machine running one app.
    func testElectronHelpersAreNotSessions() {
        let table: [pid_t: ProcessSnapshot] = [
            95245: process(95245, "/Applications/Claude.app/Contents/MacOS/Claude", name: "Claude"),
            95315: process(
                95315,
                "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
                name: "Claude Helper (Renderer)"),
            95249: process(
                95249, "/Applications/Claude.app/Contents/Frameworks/chrome_crashpad_handler",
                name: "chrome_crashpad_handler"),
        ]
        let watch = SessionWatch.fromProcessTable(table)
        XCTAssertEqual(watch.agents.count, 1)
        XCTAssertEqual(watch.agents.first?.pid, 95245)
    }

    /// Two Anthropic products ship a binary called `claude`. Naming the wrong
    /// one in a notification is small but corrosive.
    func testClaudeDesktopAndClaudeCodeAreToldApart() {
        let table: [pid_t: ProcessSnapshot] = [
            95245: process(95245, "/Applications/Claude.app/Contents/MacOS/Claude", name: "Claude"),
            115: process(
                115,
                "/Users/x/Library/Application Support/Claude/claude-code/2.1.229/claude.app/Contents/MacOS/claude",
                name: "claude"),
        ]
        let watch = SessionWatch.fromProcessTable(table)
        let byPID = Dictionary(uniqueKeysWithValues: watch.agents.map { ($0.pid, $0.providerID) })
        XCTAssertEqual(byPID[95245], "claude-desktop")
        XCTAssertEqual(byPID[115], "claude-code")
    }

    // MARK: - Persistence

    func testWatchSurvivesARoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = SessionWatch(agents: [agent(pid: 42), agent(pid: 43)])
        try SessionWatch.save(original, to: url)

        let loaded = try XCTUnwrap(SessionWatch.load(from: url))
        XCTAssertEqual(loaded.agents.count, 2)
        XCTAssertEqual(loaded.agents.map(\.pid).sorted(), [42, 43])
    }

    func testMissingWatchLoadsAsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        XCTAssertNil(SessionWatch.load(from: missing))
    }

    // MARK: - The headline

    /// It has to fit a notification, and it has to name the agent — "6
    /// processes" tells you nothing about whether you care.
    func testHeadlineNamesTheProviderAndTheDamage() {
        let event = SessionEndEvent(
            endedAgents: [agent(pid: 1)],
            leftovers: [
                leftover(id: "a", bytes: 100 << 20),
                leftover(id: "b", bytes: 200 << 20),
            ]
        )
        XCTAssertEqual(event.reclaimableBytes, 300 << 20)
        XCTAssertTrue(event.headline.contains("Claude Code"))
        XCTAssertTrue(event.headline.contains("2 leftovers"))
    }

    func testASingleLeftoverIsNotPluralised() {
        let event = SessionEndEvent(endedAgents: [agent(pid: 1)], leftovers: [leftover()])
        XCTAssertTrue(event.headline.contains("1 leftover,"))
    }

    func testTwoProvidersEndingAtOnceAreBothNamed() {
        let event = SessionEndEvent(
            endedAgents: [
                agent(pid: 1, provider: "claude-code"),
                agent(pid: 2, provider: "cursor"),
                agent(pid: 3, provider: "cursor"),  // duplicate provider, named once
            ],
            leftovers: [leftover()]
        )
        XCTAssertEqual(event.providerNames.count, 2)
        XCTAssertTrue(event.headline.contains("and"))
    }
}
