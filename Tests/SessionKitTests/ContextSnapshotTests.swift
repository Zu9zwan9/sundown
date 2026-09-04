import XCTest

@testable import SessionKit

/// The snapshot workflow exists to answer "what does this one server cost me".
/// Every test here is a way it could answer that wrongly.
final class ContextSnapshotTests: XCTestCase {

    private func record(
        _ name: String, state: ServerRecord.State = .running
    ) -> ServerRecord {
        ServerRecord(
            id: name,
            configKey: "Claude Code/\(name)",
            argv: name,
            pids: state == .running ? [1] : [],
            state: state
        )
    }

    private func snapshot(
        prefix: Int = 40_000, servers: [String] = ["pdf", "aws-api"], daysAgo: Double = 1
    ) -> ContextSnapshot {
        ContextSnapshot(
            takenAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            fixedPrefixTokens: prefix,
            servers: servers.map { record($0) },
            turnsObserved: 100
        )
    }

    // MARK: - Refusing to answer too early

    /// Disconnecting a server changes nothing Sundown can see until the agent
    /// runs again. Reporting a zero delta here would read as "that server was
    /// free" — the exact opposite of the truth.
    func testNoNewSessionsMeansNoClaim() {
        let comparison = ContextComparison(
            before: snapshot(),
            afterPrefixTokens: 40_000,
            afterServers: [record("pdf")],
            turnsSince: 0
        )
        XCTAssertFalse(comparison.hasEnoughData)

        let text = comparison.report().joined(separator: " ")
        XCTAssertTrue(text.contains("No sessions have run since"))
        // Must not print a saving it cannot support.
        XCTAssertFalse(text.contains("saved:"))
    }

    // MARK: - Counting

    /// The bug this schema exists to fix: ten processes running four servers
    /// were reported as ten servers, in the count and in the diff.
    func testDuplicateProcessesAreOneServer() {
        let doubled = ServerRecord(
            id: "pdf", configKey: "Claude Code/pdf", argv: "pdf", pids: [1, 2, 3, 4])
        let before = ContextSnapshot(
            takenAt: Date(timeIntervalSinceNow: -3600),
            fixedPrefixTokens: 40_000, servers: [doubled], turnsObserved: 100)
        XCTAssertEqual(before.running.count, 1)
        XCTAssertEqual(before.running.first?.pids.count, 4)
    }

    // MARK: - Attribution

    func testSingleRemovedServerIsChargedTheWholeDelta() {
        let comparison = ContextComparison(
            before: snapshot(prefix: 40_000, servers: ["pdf", "aws-api"]),
            afterPrefixTokens: 35_800,
            afterServers: [record("aws-api")],
            turnsSince: 25
        )
        XCTAssertEqual(comparison.removed.map(\.displayName), ["pdf"])
        XCTAssertEqual(comparison.tokensSaved, 4_200)
        XCTAssertEqual(comparison.attributable?.tokens, 4_200)

        let text = comparison.report().joined(separator: "\n")
        XCTAssertTrue(text.contains("pdf accounts for ~4,200"))
    }

    /// Removing two at once cannot separate them. Saying so is the difference
    /// between a measurement and a guess dressed as one.
    func testMultipleRemovalsAreAveragedAndFlaggedAsSuch() {
        let comparison = ContextComparison(
            before: snapshot(prefix: 40_000, servers: ["pdf", "aws-api", "prisma"]),
            afterPrefixTokens: 30_000,
            afterServers: [record("prisma")],
            turnsSince: 12
        )
        XCTAssertEqual(comparison.removed.map(\.displayName).sorted(), ["aws-api", "pdf"])
        XCTAssertNil(comparison.attributable, "attributed a delta to one of two changes")

        let text = comparison.report().joined(separator: "\n")
        XCTAssertTrue(text.contains("each on average"))
        XCTAssertTrue(text.contains("one at a time"))
    }

    /// Adding a server costs rather than saves, and the report has to say the
    /// direction out loud rather than print a negative saving.
    func testAddingAServerIsReportedAsACost() {
        let comparison = ContextComparison(
            before: snapshot(prefix: 30_000, servers: ["pdf"]),
            afterPrefixTokens: 36_000,
            afterServers: [record("pdf"), record("figma")],
            turnsSince: 8
        )
        XCTAssertEqual(comparison.added.map(\.displayName), ["figma"])
        XCTAssertEqual(comparison.tokensSaved, -6_000)

        let text = comparison.report().joined(separator: "\n")
        XCTAssertTrue(text.contains("6,000 more tokens"))
        XCTAssertFalse(text.contains("saved:"))
    }

    /// A server still in the config with no process is not a saving. Calling it
    /// "removed" told the user they had banked a cost when what they actually
    /// had was a server that had stopped working.
    func testAStoppedServerIsNotReportedAsRemoved() {
        let comparison = ContextComparison(
            before: snapshot(prefix: 40_000, servers: ["prisma", "pdf"]),
            afterPrefixTokens: 36_000,
            afterServers: [record("pdf"), record("prisma", state: .declaredNotRunning)],
            turnsSince: 20
        )
        XCTAssertTrue(comparison.removed.isEmpty)
        XCTAssertEqual(comparison.stopped.map(\.displayName), ["prisma"])

        let text = comparison.report().joined(separator: "\n")
        XCTAssertTrue(text.contains("still declared, not running"))
    }

    /// The delta has to move the way the change would move it. A server that
    /// left while the charge went *up* did not cause the rise.
    func testAttributionRequiresTheDeltaToPointTheRightWay() {
        let comparison = ContextComparison(
            before: snapshot(prefix: 30_000, servers: ["pdf"]),
            afterPrefixTokens: 35_000,
            afterServers: [],
            turnsSince: 10
        )
        XCTAssertNil(comparison.attributable)
    }

    /// Correlation is all this method can establish. Dropping the caveat would
    /// turn a bounded claim into a false one.
    func testReportNeverClaimsCausation() {
        let comparison = ContextComparison(
            before: snapshot(),
            afterPrefixTokens: 35_000,
            afterServers: [record("aws-api")],
            turnsSince: 40
        )
        let text = comparison.report().joined(separator: "\n")
        XCTAssertTrue(text.contains("Coincidence, not proof"))
    }

    // MARK: - Persistence

    func testSnapshotSurvivesARoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = snapshot(prefix: 39_358, servers: ["b", "a"])
        try ContextSnapshot.save(original, to: url)

        let loaded = try ContextSnapshot.load(from: url)
        XCTAssertEqual(loaded.fixedPrefixTokens, 39_358)
        XCTAssertFalse(loaded.migrated)
        // Sorted on init so diffing two snapshots is order-independent.
        XCTAssertEqual(loaded.servers.map(\.displayName), ["a", "b"])
        XCTAssertEqual(
            loaded.takenAt.timeIntervalSince1970,
            original.takenAt.timeIntervalSince1970,
            accuracy: 1
        )
    }

    /// A v1 file is migrated rather than reinterpreted. Its token figures were
    /// always right; its server list counted processes, so it is deduplicated
    /// and flagged, and nothing gains a config key it never had.
    func testOldSnapshotsMigrateWithoutInventingIdentity() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("v1-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"""
            {"fixedPrefixTokens":39358,
             "servers":["pdf","pdf","pdf","pdf","aws-api","aws-api","prisma mcp","prisma mcp"],
             "takenAt":"2026-08-14T23:13:01Z","turnsObserved":795}
            """#.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try ContextSnapshot.load(from: url)
        XCTAssertTrue(loaded.migrated)
        XCTAssertEqual(loaded.fixedPrefixTokens, 39_358)
        XCTAssertEqual(loaded.servers.count, 3, "duplicates were counted as servers")
        XCTAssertTrue(loaded.servers.allSatisfy { $0.configKey == nil })
        XCTAssertTrue(
            ContextComparison(
                before: loaded, afterPrefixTokens: 1, afterServers: [], turnsSince: 1
            ).report().joined(separator: "\n").contains("predates server identity"))
    }

    /// A file that exists and cannot be parsed is not an empty baseline.
    /// Treating it as one would manufacture a saving out of a read error.
    func testAnUnreadableSnapshotFailsLoudlyRatherThanResettingToZero() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("junk-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try "{ not json at all".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ContextSnapshot.load(from: url)) { error in
            guard case ContextSnapshot.LoadFailure.unreadable = error else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }

    func testMissingSnapshotReportsItAsMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString).json")
        XCTAssertThrowsError(try ContextSnapshot.load(from: missing)) { error in
            guard case ContextSnapshot.LoadFailure.missing = error else {
                return XCTFail("expected .missing, got \(error)")
            }
        }
    }
}

/// Per-server attribution of *active* cost, which — unlike the fixed prefix —
/// is exact, because the server name is embedded in every MCP tool name.
final class ServerAttributionTests: XCTestCase {

    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attr-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testCallsAndResultsAreChargedToTheRightServer() throws {
        let url = try write([
            #"{"uuid":"1","message":{"content":[{"type":"tool_use","id":"c1","name":"mcp__pdf__read"}]}}"#,
            #"{"uuid":"2","message":{"content":[{"type":"tool_result","tool_use_id":"c1","content":"0123456789"}]}}"#,
            #"{"uuid":"3","message":{"content":[{"type":"tool_use","id":"c2","name":"mcp__aws-api__list"}]}}"#,
            #"{"uuid":"4","message":{"content":[{"type":"tool_result","tool_use_id":"c2","content":"ab"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = TranscriptMetrics.parse(url)
        XCTAssertEqual(parsed.calls["pdf"], 1)
        XCTAssertEqual(parsed.calls["aws-api"], 1)
        XCTAssertGreaterThan(parsed.resultCharacters["pdf"] ?? 0, 0)
        XCTAssertGreaterThan(
            parsed.resultCharacters["pdf"] ?? 0,
            parsed.resultCharacters["aws-api"] ?? 0
        )
    }

    /// Built-in tools are not MCP servers and must not appear in the breakdown.
    func testBuiltInToolsAreNotAttributedToAnyServer() throws {
        let url = try write([
            #"{"uuid":"1","message":{"content":[{"type":"tool_use","id":"c1","name":"Read"}]}}"#,
            #"{"uuid":"2","message":{"content":[{"type":"tool_use","id":"c2","name":"mcp__only"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = TranscriptMetrics.parse(url)
        XCTAssertTrue(parsed.calls.isEmpty, "attributed a non-MCP tool: \(parsed.calls)")
    }

    /// Tool results arrive as bare strings, numbers, arrays, and dictionaries.
    /// An earlier version handed each one to JSONSerialization, which raises an
    /// **ObjC exception** for a non-collection top-level value — uncatchable by
    /// `try?`, so the process died. Every shape below must be survivable.
    func testEveryResultShapeIsMeasuredWithoutCrashing() throws {
        let url = try write([
            #"{"uuid":"1","message":{"content":[{"type":"tool_use","id":"a","name":"mcp__s__t"}]}}"#,
            #"{"uuid":"2","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"plain string"}]}}"#,
            #"{"uuid":"3","message":{"content":[{"type":"tool_use","id":"b","name":"mcp__s__t"}]}}"#,
            #"{"uuid":"4","message":{"content":[{"type":"tool_result","tool_use_id":"b","content":42}]}}"#,
            #"{"uuid":"5","message":{"content":[{"type":"tool_use","id":"c","name":"mcp__s__t"}]}}"#,
            #"{"uuid":"6","message":{"content":[{"type":"tool_result","tool_use_id":"c","content":[{"type":"text","text":"in an array"}]}]}}"#,
            #"{"uuid":"7","message":{"content":[{"type":"tool_use","id":"d","name":"mcp__s__t"}]}}"#,
            #"{"uuid":"8","message":{"content":[{"type":"tool_result","tool_use_id":"d","content":null}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = TranscriptMetrics.parse(url)
        XCTAssertEqual(parsed.calls["s"], 4)
        // The string, the number and the array all contribute; null does not.
        XCTAssertGreaterThan(parsed.resultCharacters["s"] ?? 0, "plain string".utf8.count)
    }

    /// A result whose call was never seen has no owner. Guessing one would put
    /// somebody else's tokens on a server's bill.
    func testOrphanResultsAreNotAttributed() throws {
        let url = try write([
            #"{"uuid":"1","message":{"content":[{"type":"tool_result","tool_use_id":"ghost","content":"xxxxxxxx"}]}}"#
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = TranscriptMetrics.parse(url)
        XCTAssertTrue(parsed.resultCharacters.isEmpty)
    }

    func testUsageRanksByCostNotByCallCount() {
        let metrics = TranscriptMetrics(
            turns: [.init(input: 1, cacheCreation: 10, cacheRead: 0, output: 1)],
            sessionCount: 1,
            serverUsage: [
                .init(server: "chatty", calls: 50, resultCharacters: 4_000),
                .init(server: "heavy", calls: 3, resultCharacters: 400_000),
            ]
        )
        // 3 calls that return novels cost more than 50 that return a line.
        XCTAssertEqual(metrics.serversByCost.first?.server, "heavy")
        XCTAssertEqual(metrics.totalActiveTokens, (400_000 + 4_000) / 4)
    }
}
