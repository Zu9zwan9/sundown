import XCTest

@testable import SessionKit

/// This report tells someone to disconnect something. Every test here is a way
/// it could tell them to disconnect the wrong thing.
final class IdleServerReportTests: XCTestCase {

    private func metrics(
        usage: [(String, Int)],
        prefix: Int = 40_000,
        sessions: Int = 10
    ) -> TranscriptMetrics {
        TranscriptMetrics(
            turns: [.init(input: 1, cacheCreation: prefix - 1, cacheRead: 0, output: 1)],
            sessionCount: sessions,
            serverUsage: usage.map {
                .init(server: $0.0, calls: $0.1, resultCharacters: $0.1 * 400)
            }
        )
    }

    private func declaration(
        _ name: String, client: String = "Claude Code"
    ) -> MCPRegistry.Declaration {
        .init(name: name, client: client, fingerprint: name)
    }

    /// A server the scan matched to a declaration, with its call count already
    /// attributed — the shape `ServerRecord.build` produces.
    private func running(
        _ name: String, client: String = "Claude Code", calls: Int
    ) -> ServerRecord {
        ServerRecord(
            id: declaration(name, client: client).transcriptID,
            configKey: "\(client)/\(name)",
            argv: name,
            pids: [1],
            tokens: calls * 100,
            calls: calls
        )
    }

    // MARK: - The accusation

    func testAServerWithNoCallsIsReportedIdle() {
        let report = IdleServerReport.build(
            servers: [running("pdf", calls: 0), running("github", calls: 12)],
            registry: MCPRegistry(declarations: [declaration("pdf"), declaration("github")]),
            metrics: metrics(usage: [("github", 12)])
        )
        XCTAssertEqual(report.idle.map(\.server), ["pdf"])
        XCTAssertEqual(report.used.map(\.server), ["github"])
        XCTAssertTrue(report.report().joined().contains("never called"))
    }

    /// The single most damaging failure available to this feature.
    ///
    /// Claude Desktop's servers do not appear in Claude Code's transcripts, so
    /// judging them by that history declares every one of them idle and
    /// attributes a standing charge they never contributed to. Found by running
    /// the real binary: "4 of 4 connected servers were never called", with 100%
    /// of a 63,672-token prefix blamed on them.
    ///
    /// The guard is now per client and exact: none of Claude Desktop's declared
    /// ids appear in this corpus, so this corpus cannot speak about them.
    func testServersFromAnotherClientAreNotAccusedOfBeingIdle() {
        let desktop = ["aws-api", "pdf", "prisma"].map { declaration($0, client: "Claude Desktop") }
        let report = IdleServerReport.build(
            servers: ["aws-api", "pdf", "prisma"].map {
                running($0, client: "Claude Desktop", calls: 0)
            },
            registry: MCPRegistry(declarations: desktop),
            // Traffic exists, but from a completely different client's tools.
            metrics: metrics(usage: [("workspace", 75), ("cowork", 13)])
        )

        XCTAssertTrue(report.idle.isEmpty, "accused another client's servers of being idle")
        XCTAssertEqual(report.unknown.count, 3)
        XCTAssertEqual(report.estimatedIdleTokens, 0, "billed servers that were never judged")

        let text = report.report().joined(separator: "\n")
        XCTAssertTrue(text.contains("aren't in the folders Sundown reads"))
        XCTAssertFalse(text.contains("never called"))
    }

    /// One genuine match is enough to trust the corpus for the rest of it —
    /// and the match may come from a declaration that isn't currently running,
    /// which is what lets a client whose servers are all idle still be judged.
    func testEvidenceFromAnyDeclarationOfTheClientUnlocksAVerdict() {
        let report = IdleServerReport.build(
            servers: [running("pdf", calls: 0)],
            registry: MCPRegistry(declarations: [declaration("pdf"), declaration("context7")]),
            metrics: metrics(usage: [("context7", 4)])
        )
        XCTAssertEqual(report.idle.map(\.server), ["pdf"])
    }

    /// No tool traffic at all is not evidence of disuse.
    func testNoToolTrafficMeansNoVerdict() {
        let report = IdleServerReport.build(
            servers: [running("pdf", calls: 0), running("github", calls: 0)],
            registry: MCPRegistry(declarations: [declaration("pdf"), declaration("github")]),
            metrics: metrics(usage: [])
        )
        XCTAssertTrue(report.idle.isEmpty)
        XCTAssertEqual(report.unknown.count, 2)
    }

    // MARK: - Identity

    /// No config declaration means no join key. The old code guessed from the
    /// process name; this abstains and says which link broke.
    func testAnUnidentifiedProcessIsNeverCalledIdle() {
        let stranger = ServerRecord(
            id: "node", configKey: nil, argv: "node /tmp/whatever.js", pids: [7])
        let report = IdleServerReport.build(
            servers: [stranger, running("github", calls: 3)],
            registry: MCPRegistry(declarations: [declaration("github")]),
            metrics: metrics(usage: [("github", 3)])
        )
        XCTAssertTrue(report.idle.isEmpty)
        XCTAssertEqual(report.unknown.map(\.server), ["node"])
        XCTAssertEqual(report.unknown.first?.abstention, .unidentifiedProcess)
        XCTAssertTrue(
            report.report().joined(separator: "\n").contains("no config declaration matches"))
    }

    /// The rule the whole join rests on: a client turns its config key into a
    /// tool prefix by replacing anything that isn't a letter, digit or hyphen.
    func testConfigKeysSanitiseIntoTranscriptIDs() {
        XCTAssertEqual(declaration("elevenlabs").transcriptID, "elevenlabs")
        XCTAssertEqual(declaration("mcp-unframer-co").transcriptID, "mcp-unframer-co")
        XCTAssertEqual(declaration("claude.ai Notion").transcriptID, "claude_ai_Notion")
        XCTAssertEqual(
            declaration("plugin:aws-startup-advisor:awspricing").transcriptID,
            "plugin_aws-startup-advisor_awspricing")
    }

    /// A declared server with no process is not idle and not removed. It is a
    /// third thing, and the one the user is most likely to be wrong about.
    func testDeclaredButNotRunningIsItsOwnBucket() {
        let absent = ServerRecord(
            id: "jbcontext", configKey: "Claude Code/jbcontext", argv: "jbcontext",
            pids: [], state: .declaredNotRunning)
        let report = IdleServerReport.build(
            servers: [absent, running("github", calls: 3)],
            registry: MCPRegistry(declarations: [declaration("github")]),
            metrics: metrics(usage: [("github", 3)])
        )
        XCTAssertEqual(report.notRunning.map(\.server), ["jbcontext"])
        XCTAssertTrue(report.idle.isEmpty)
        XCTAssertEqual(report.connectedCount, 1, "counted a server with no process as connected")
        XCTAssertTrue(report.report().joined(separator: "\n").contains("Declared but not running"))
    }

    // MARK: - The number

    /// The saving is a proportional estimate over a prefix that also contains
    /// the system prompt. Presenting it as exact would invite someone to budget
    /// against it.
    func testIdleTokenEstimateIsProportionalAndCaveated() {
        let names = ["a", "b", "c", "d"]
        let report = IdleServerReport.build(
            servers: names.map { running($0, calls: $0 == "a" ? 5 : 0) },
            registry: MCPRegistry(declarations: names.map { declaration($0) }),
            metrics: metrics(usage: [("a", 5)], prefix: 40_000)
        )
        XCTAssertEqual(report.idle.count, 3)
        XCTAssertEqual(report.estimatedIdleTokens, 30_000)

        let text = report.report().joined(separator: "\n")
        XCTAssertTrue(text.contains("roughly"))
        XCTAssertTrue(text.contains("--snapshot"))
    }

    func testNothingConnectedSaysSoPlainly() {
        let report = IdleServerReport.build(
            servers: [],
            registry: MCPRegistry(declarations: []),
            metrics: metrics(usage: [("workspace", 5)])
        )
        XCTAssertEqual(report.connectedCount, 0)
        XCTAssertTrue(report.report().joined().contains("No MCP servers"))
    }
}

// MARK: - Headroom

/// The number nothing else in this category can compute, because it needs the
/// connected set and not just the spend. Kept honest by being a pure ratio.
extension IdleServerReportTests {

    private func report(used: Int, idle: Int, prefix: Int) -> IdleServerReport {
        IdleServerReport(
            used: (0..<used).map { .init(record: running("used\($0)", calls: 5), calls: 5) },
            idle: (0..<idle).map { .init(record: running("idle\($0)", calls: 0), calls: 0) },
            unknown: [],
            fixedPrefixTokens: prefix,
            sessionsExamined: 10
        )
    }

    func testHalfTheServersIdleDoublesTheRequests() {
        let r = report(used: 1, idle: 1, prefix: 100_000)
        XCTAssertEqual(r.estimatedIdleTokens, 50_000)
        XCTAssertEqual(try XCTUnwrap(r.requestHeadroomMultiplier), 2.0, accuracy: 0.001)
    }

    func testNothingIdleMeansNoHeadroomClaim() {
        XCTAssertNil(report(used: 3, idle: 0, prefix: 100_000).requestHeadroomMultiplier)
    }

    /// If every connected server is idle the remainder is zero and the ratio is
    /// undefined. Returning a huge number here would print a boast.
    func testEveryServerIdleClaimsNothingRatherThanInfinity() {
        XCTAssertNil(report(used: 0, idle: 2, prefix: 100_000).requestHeadroomMultiplier)
    }

    func testHeadroomAppearsInTheReport() {
        let lines = report(used: 3, idle: 1, prefix: 100_000).report().joined(separator: "\n")
        XCTAssertTrue(lines.contains("more requests"), lines)
    }
}

/// Reading the synced plugin directory turned this section from eight lines
/// into twenty-three: every plugin the user had installed and never opened.
/// The question it answers is "did something I expected fail to start", and a
/// plugin inventory answers a question nobody asked.
final class DeclaredNotRunningTests: XCTestCase {

    private func declaration(_ name: String) -> MCPRegistry.Declaration {
        .init(name: name, client: "Claude Code", fingerprint: name)
    }

    private func build(usage: [(String, Int)]) -> [ServerRecord] {
        ServerRecord.build(
            targets: [],
            table: [:],
            registry: MCPRegistry(declarations: [
                declaration("jbcontext"), declaration("plugin:pubmed:FHIR"),
            ]),
            metrics: TranscriptMetrics(
                turns: [.init(input: 1, cacheCreation: 40_000, cacheRead: 0, output: 1)],
                sessionCount: 10,
                serverUsage: usage.map {
                    .init(server: $0.0, calls: $0.1, resultCharacters: $0.1 * 400)
                }
            ),
            agentClients: ["Claude Code"]
        )
    }

    func testAServerYouHaveUsedAndThatIsGoneIsWorthSaying() {
        let absent = build(usage: [("jbcontext", 23)])
            .filter { $0.state == .declaredNotRunning }
            .map(\.configKey)
        XCTAssertEqual(absent, ["Claude Code/jbcontext"])
    }

    /// The plugin has never been called in any session. Its absence from the
    /// process table is not news.
    func testAServerYouHaveNeverCalledIsNotAnAbsence() {
        let absent = build(usage: [])
            .filter { $0.state == .declaredNotRunning }
        XCTAssertTrue(absent.isEmpty, "got \(absent.map(\.configKey))")
    }
}
