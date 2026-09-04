import XCTest

@testable import SessionKit

/// These numbers get shown to someone deciding whether to disconnect a server.
/// Every test here is a way the report could mislead them.
final class TranscriptMetricsTests: XCTestCase {

    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sundown-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func turnLine(
        uuid: String, input: Int, creation: Int, read: Int, output: Int, timestamp: String? = nil
    ) -> String {
        // Built in one piece rather than patched afterwards. An earlier version
        // appended the timestamp by trimming a brace, which nested it inside
        // `message` and left the outer object unclosed — the fixture was
        // malformed and the test failed for a reason that had nothing to do
        // with the code under test.
        let stamp = timestamp.map { ",\"timestamp\":\"\($0)\"" } ?? ""
        return """
            {"uuid":"\(uuid)"\(stamp),"message":{"usage":{"input_tokens":\(input),\
            "cache_creation_input_tokens":\(creation),\
            "cache_read_input_tokens":\(read),"output_tokens":\(output)}}}
            """
    }

    /// Guards the helper above: if the fixture stops being valid JSON, every
    /// test in this file starts passing or failing for the wrong reason.
    func testFixtureBuilderProducesValidJSON() throws {
        for stamp in [nil, "2026-08-14T10:00:00.000Z"] {
            let line = turnLine(
                uuid: "x", input: 1, creation: 2, read: 3, output: 4, timestamp: stamp)
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            XCTAssertNotNil(object as? [String: Any], "fixture is not a JSON object: \(line)")
        }
    }

    // MARK: - The headline number

    /// The standing charge is the floor, not the average. Reporting the mean
    /// would fold in conversation growth and overstate what disconnecting a
    /// server gives back.
    func testFixedPrefixIsTheLeanestTurnNotTheAverage() throws {
        let url = try write([
            turnLine(uuid: "a", input: 2, creation: 40_000, read: 0, output: 100),
            turnLine(uuid: "b", input: 2, creation: 5_000, read: 300_000, output: 100),
            turnLine(uuid: "c", input: 2, creation: 1_000, read: 800_000, output: 100),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let metrics = TranscriptMetrics(turns: TranscriptMetrics.parse(url).turns, sessionCount: 1)
        XCTAssertEqual(metrics.turns.count, 3)
        XCTAssertEqual(metrics.fixedPrefixTokens, 40_002)
        XCTAssertEqual(metrics.peakInputTokens, 801_002)
    }

    /// Streaming writes a turn more than once. Counting duplicates would
    /// inflate every total in the report.
    func testRepeatedTurnsAreCountedOnce() throws {
        let line = turnLine(uuid: "same", input: 2, creation: 10_000, read: 0, output: 50)
        let url = try write([line, line, line])
        defer { try? FileManager.default.removeItem(at: url) }

        let metrics = TranscriptMetrics(turns: TranscriptMetrics.parse(url).turns, sessionCount: 1)
        XCTAssertEqual(metrics.turns.count, 1)
        XCTAssertEqual(metrics.totalCacheCreation, 10_000)
    }

    /// Transcripts interleave many record types, and a half-written final line
    /// is normal for a session still in progress. Neither may throw off the
    /// numbers or crash the scan.
    func testNonUsageAndMalformedLinesAreIgnored() throws {
        let url = try write([
            #"{"type":"user","message":{"content":"hello"}}"#,
            "not json at all",
            #"{"type":"summary"}"#,
            turnLine(uuid: "real", input: 1, creation: 9_000, read: 0, output: 20),
            #"{"uuid":"truncated","message":{"usa"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let metrics = TranscriptMetrics(turns: TranscriptMetrics.parse(url).turns, sessionCount: 1)
        XCTAssertEqual(metrics.turns.count, 1)
        XCTAssertEqual(metrics.fixedPrefixTokens, 9_001)
    }

    /// A turn with no token counts is not a turn. Including it would drag the
    /// floor to zero and make the standing charge read as free.
    func testZeroTokenRecordsCannotDragTheFloorToZero() throws {
        let url = try write([
            turnLine(uuid: "empty", input: 0, creation: 0, read: 0, output: 0),
            turnLine(uuid: "real", input: 2, creation: 30_000, read: 0, output: 10),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let metrics = TranscriptMetrics(turns: TranscriptMetrics.parse(url).turns, sessionCount: 1)
        XCTAssertEqual(metrics.turns.count, 1)
        XCTAssertEqual(metrics.fixedPrefixTokens, 30_002)
    }

    // MARK: - Refusing to invent

    /// Two turns a minute apart cannot support a per-day rate. Extrapolating
    /// from them would produce a confident number with nothing behind it.
    func testRateIsWithheldWhenTheWindowIsTooShort() throws {
        let url = try write([
            turnLine(
                uuid: "a", input: 2, creation: 10_000, read: 0, output: 10,
                timestamp: "2026-08-14T10:00:00.000Z"),
            turnLine(
                uuid: "b", input: 2, creation: 10_000, read: 0, output: 10,
                timestamp: "2026-08-14T10:01:00.000Z"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let metrics = TranscriptMetrics(turns: TranscriptMetrics.parse(url).turns, sessionCount: 1)
        XCTAssertNil(metrics.turnsPerDay)
        XCTAssertNil(metrics.projectedDailyFixedTokens)
    }

    func testRateIsReportedOnceTheWindowIsWideEnough() throws {
        let url = try write([
            turnLine(
                uuid: "a", input: 2, creation: 10_000, read: 0, output: 10,
                timestamp: "2026-08-12T10:00:00.000Z"),
            turnLine(
                uuid: "b", input: 2, creation: 10_000, read: 0, output: 10,
                timestamp: "2026-08-14T10:00:00.000Z"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let metrics = TranscriptMetrics(turns: TranscriptMetrics.parse(url).turns, sessionCount: 1)
        XCTAssertEqual(metrics.turnsPerDay ?? 0, 1.0, accuracy: 0.01)
    }

    /// One tiny sub-agent session must not define the standing charge for all
    /// of them.
    ///
    /// Found live: adding plugin-hosted transcripts to the search introduced
    /// sub-agent sessions whose whole prefix is ~20 tokens. Taking the global
    /// minimum reported the standing charge as 20 and "0% of a 200,000-token
    /// window" — from 67,539, which is the real figure.
    func testATinySubAgentSessionCannotDefineTheStandingCharge() {
        let metrics = TranscriptMetrics(
            turns: [.init(input: 1, cacheCreation: 20, cacheRead: 0, output: 1)],
            sessionCount: 4,
            sessionFloors: [66_000, 67_539, 69_000, 20]
        )
        XCTAssertEqual(metrics.fixedPrefixTokens, 67_539)
        XCTAssertGreaterThan(metrics.windowShare(contextWindow: 200_000), 0.3)
    }

    /// Metrics built without a per-session breakdown still work — that's the
    /// path every other test in this file takes.
    func testFloorFallsBackToTheGlobalMinimumWithoutSessionData() {
        let metrics = TranscriptMetrics(
            turns: [
                .init(input: 1, cacheCreation: 900, cacheRead: 0, output: 1),
                .init(input: 1, cacheCreation: 40_000, cacheRead: 0, output: 1),
            ],
            sessionCount: 1
        )
        XCTAssertEqual(metrics.fixedPrefixTokens, 901)
    }

    /// With nothing measured, the report has to say so rather than print zeros
    /// that read like a finding.
    func testEmptyMetricsSayNothingWasMeasured() {
        let metrics = TranscriptMetrics(turns: [], sessionCount: 0)
        XCTAssertTrue(metrics.isEmpty)
        XCTAssertEqual(metrics.fixedPrefixTokens, 0)
        XCTAssertTrue(metrics.explanation().contains { $0.contains("No transcripts found") })
    }

    /// The per-server line divides a prefix that includes the system prompt, so
    /// it must be presented as a ceiling. Dropping that caveat would turn a
    /// bounded claim into a false one.
    func testPerServerFigureIsLabelledAsACeiling() {
        let metrics = TranscriptMetrics(
            turns: [.init(input: 2, cacheCreation: 40_000, cacheRead: 0, output: 10)],
            sessionCount: 1
        )
        let text = metrics.explanation(serverCount: 10).joined(separator: "\n")
        XCTAssertTrue(text.contains("ceiling"), "per-server figure presented without its caveat")
    }

    /// Cache reads are billed at a fraction of fresh input. Printing a large
    /// cache figure without that note invites reading it as money.
    func testCacheTotalsCarryTheBillingCaveat() {
        let metrics = TranscriptMetrics(
            turns: [.init(input: 2, cacheCreation: 1_000, cacheRead: 500_000, output: 10)],
            sessionCount: 1
        )
        let text = metrics.explanation().joined(separator: "\n")
        XCTAssertTrue(text.contains("context pressure, not spend"))
    }
}
