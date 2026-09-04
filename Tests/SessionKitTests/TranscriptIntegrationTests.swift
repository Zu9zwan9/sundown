import XCTest

@testable import SessionKit

/// Runs against whatever real transcripts this machine has.
///
/// Synthetic fixtures prove the parser handles the shapes I thought of. This
/// proves it handles the shapes that actually occur — which is a different and
/// larger set. Skips cleanly on a machine with no transcripts, so CI stays
/// green without pretending it verified anything.
final class TranscriptIntegrationTests: XCTestCase {

    /// Honours `SUNDOWN_TRANSCRIPT_ROOT` so this can be pointed at a specific
    /// directory. The default roots depend on `TMPDIR`, which the test runner
    /// sets differently from a login shell — meaning the test and the shipped
    /// CLI can silently read different transcript sets, which is exactly the
    /// confusion that cost an hour here.
    private var roots: [URL] {
        if let override = ProcessInfo.processInfo.environment["SUNDOWN_TRANSCRIPT_ROOT"] {
            return [URL(fileURLWithPath: override)]
        }
        return TranscriptMetrics.defaultSearchRoots()
    }

    func testRealTranscriptsParseIntoUsableNumbers() throws {
        try XCTSkipIf(roots.isEmpty, "no transcript directories on this machine")

        let files = TranscriptMetrics.transcriptFiles(under: roots, limit: 200)
        try XCTSkipIf(files.isEmpty, "no transcripts found")

        let metrics = TranscriptMetrics.load(roots: roots, limit: 200)
        XCTAssertFalse(metrics.isEmpty, "found \(files.count) transcripts but parsed no turns")
        XCTAssertGreaterThan(metrics.fixedPrefixTokens, 0)

        // Diagnostics — these print on failure and when run verbosely, which is
        // how the per-server breakdown coming back empty got noticed at all.
        print("  transcripts: \(files.count)")
        print("  turns:       \(metrics.turns.count)")
        print("  prefix:      \(metrics.fixedPrefixTokens)")
        print("  servers:     \(metrics.serverUsage.count)")
        for usage in metrics.serversByCost.prefix(6) {
            print("    \(usage.server): \(usage.calls) calls, \(usage.resultCharacters) chars")
        }
    }

    /// Any machine that has used an MCP server has tool_use records to find.
    /// Zero attributed servers alongside thousands of turns means the parser is
    /// silently skipping content blocks — which is exactly what happened.
    func testToolTrafficIsAttributedWhenTranscriptsContainIt() throws {
        try XCTSkipIf(roots.isEmpty, "no transcript directories on this machine")

        let files = TranscriptMetrics.transcriptFiles(under: roots, limit: 200)
        var mcpCallsSeenRaw = 0
        for file in files.prefix(40) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            mcpCallsSeenRaw += text.components(separatedBy: "\"name\":\"mcp__").count - 1
        }
        try XCTSkipIf(mcpCallsSeenRaw == 0, "no MCP tool calls in local transcripts")

        let metrics = TranscriptMetrics.load(roots: roots, limit: 200)
        XCTAssertFalse(
            metrics.serverUsage.isEmpty,
            """
            Raw text shows \(mcpCallsSeenRaw) mcp__ tool calls across the transcripts, \
            but the parser attributed none. Content-block parsing is broken.
            """
        )
    }
}
