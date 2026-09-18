import XCTest

@testable import SessionKit

/// This is the only thing in the project that is meant to leave the machine,
/// and it leaves by the person's own hand. These tests are mostly about what it
/// refuses to say.
final class ContributionDocumentTests: XCTestCase {

    private func declaration(_ name: String, client: String) -> MCPRegistry.Declaration {
        .init(name: name, client: client, fingerprint: name)
    }

    /// Matched to a declaration — the shape that may be published.
    private func matched(_ name: String, client: String = "Claude Code", calls: Int)
        -> ServerRecord
    {
        ServerRecord(
            id: declaration(name, client: client).transcriptID,
            configKey: "\(client)/\(name)",
            argv: name,
            pids: [1],
            tokens: calls * 100,
            calls: calls
        )
    }

    /// No config declaration matched — the shape that may not.
    private func unmatched(_ argv: String) -> ServerRecord {
        ServerRecord(id: argv, configKey: nil, argv: argv, pids: [2], tokens: 0, calls: 0)
    }

    private func report(
        used: [(String, Int)] = [],
        idle: [String] = [],
        unknown: [String] = [],
        client: String = "Claude Code",
        prefix: Int = 74_031
    ) -> IdleServerReport {
        IdleServerReport(
            used: used.map {
                .init(record: matched($0.0, client: client, calls: $0.1), calls: $0.1)
            },
            idle: idle.map { .init(record: matched($0, client: client, calls: 0), calls: 0) },
            unknown: unknown.map { .init(record: unmatched($0), calls: 0) },
            fixedPrefixTokens: prefix,
            sessionsExamined: 76
        )
    }

    // MARK: - What it carries

    func testCarriesTheMeasuredTotalAndTheExactSet() throws {
        let doc = try XCTUnwrap(
            ContributionDocument.build(from: report(used: [("jbcontext", 23)], idle: ["awspricing"]))
        )
        XCTAssertEqual(doc.standingChargeTokens, 74_031)
        XCTAssertEqual(doc.sessionsExamined, 76)
        XCTAssertEqual(doc.servers.map(\.id), ["awspricing", "jbcontext"])
        XCTAssertEqual(doc.servers.first { $0.id == "jbcontext" }?.calls, 23)
        XCTAssertEqual(doc.servers.first { $0.id == "awspricing" }?.calls, 0)
    }

    /// The id must be the bare name the registry uses, not `client/name`, or
    /// nobody can look the row up.
    func testTheClientPrefixIsStrippedFromTheID() throws {
        let doc = try XCTUnwrap(ContributionDocument.build(from: report(used: [("github", 4)])))
        XCTAssertEqual(doc.servers.map(\.id), ["github"])
        XCTAssertEqual(doc.client, "Claude Code")
    }

    func testAMachineSpanningTwoClientsSaysSoRatherThanPicking() throws {
        let mixed = IdleServerReport(
            used: [
                .init(record: matched("github", client: "Claude Code", calls: 4), calls: 4),
                .init(record: matched("pdf", client: "Claude Desktop", calls: 1), calls: 1),
            ],
            idle: [], unknown: [], fixedPrefixTokens: 50_000, sessionsExamined: 10
        )
        XCTAssertEqual(try XCTUnwrap(ContributionDocument.build(from: mixed)).client, "mixed")
    }

    /// The same set on two machines must serialise identically or the index
    /// cannot deduplicate, and every row looks like new evidence.
    func testServerOrderIsStableRegardlessOfInputOrder() throws {
        let a = try XCTUnwrap(ContributionDocument.build(from: report(used: [("zulu", 1), ("alpha", 2)])))
        let b = try XCTUnwrap(ContributionDocument.build(from: report(used: [("alpha", 2), ("zulu", 1)])))
        XCTAssertEqual(a.servers.map(\.id), ["alpha", "zulu"])
        XCTAssertEqual(try a.json(), try b.json())
    }

    // MARK: - What it refuses to say

    /// Sundown abstains locally on servers it cannot match to a declaration. A
    /// row it would not judge for its owner must not become evidence about
    /// somebody else's machine.
    func testUnmatchedServersAreNeverPublished() throws {
        let doc = try XCTUnwrap(
            ContributionDocument.build(
                from: report(used: [("github", 4)], unknown: ["node", "wrapper"]))
        )
        XCTAssertEqual(doc.servers.map(\.id), ["github"])
    }

    func testNothingIdentifiedMeansNoDocument() {
        XCTAssertNil(ContributionDocument.build(from: report(unknown: ["node"])))
    }

    /// A set with no measured number behind it is a vote with no evidence.
    func testNoStandingChargeMeansNoDocument() {
        XCTAssertNil(ContributionDocument.build(from: report(used: [("github", 4)], prefix: 0)))
    }

    /// Day precision. A timestamp to the second is a fingerprint.
    func testDateIsDayPrecisionOnly() throws {
        let doc = try XCTUnwrap(
            ContributionDocument.build(
                from: report(used: [("github", 4)]),
                on: Date(timeIntervalSince1970: 1_789_700_000))
        )
        XCTAssertEqual(doc.submittedAt.count, 10, doc.submittedAt)
        XCTAssertFalse(doc.submittedAt.contains(":"))
    }

    /// The reviewable-by-a-human property, asserted rather than assumed.
    func testJSONCarriesNoPathsAndIsReadable() throws {
        let json = try XCTUnwrap(ContributionDocument.build(from: report(used: [("github", 4)])))
            .json()
        XCTAssertFalse(json.contains("/Users/"))
        XCTAssertFalse(json.contains(NSHomeDirectory()))
        XCTAssertTrue(json.contains("\n"), "must be pretty-printed for review")
        XCTAssertTrue(json.contains("\"schema\" : 1"))
    }

    func testRoundTrips() throws {
        let doc = try XCTUnwrap(
            ContributionDocument.build(from: report(used: [("github", 4)], idle: ["pdf"])))
        let decoded = try JSONDecoder().decode(
            ContributionDocument.self, from: Data(doc.json().utf8))
        XCTAssertEqual(decoded, doc)
    }
}
