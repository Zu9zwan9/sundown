import Foundation

/// Servers you are paying for and never calling.
///
/// This is the one question Sundown can answer that nothing else can, and the
/// reason is structural rather than clever: answering it requires *both* the
/// live process table and the session transcripts, and no other tool reads
/// both.
///
/// - `claude /context` and `/doctor` report what your tool definitions cost.
///   They see what is loaded. They cannot see what you used, because that
///   information lives in history they don't read.
/// - Transcript readers (ccusage and friends) see what you used. They cannot
///   see what is *connected*, because that lives in the process table.
///
/// Cost alone is not actionable — every server costs something, and you keep
/// the ones you need. Usage alone is not actionable either. The ratio is what
/// tells you what to disconnect, and the ratio needs the join.
///
/// The join is exact. A process is matched to the config declaration that
/// spawned it, and that declaration's key sanitises into the `mcp__<id>__`
/// prefix the transcript records — a rule the client follows, not a
/// similarity score. When the config cannot identify a process, this abstains
/// and says which link of the chain broke. Nothing here guesses at a name:
/// calling a server idle when it isn't is how a tool like this loses trust in
/// one screenshot.
public struct IdleServerReport: Sendable {

    /// Why a server could not be judged. Every one of these is a specific
    /// broken link, printed as such — "no evidence either way" told the user
    /// nothing they could act on.
    public enum Abstention: Sendable, Hashable {
        /// A running process no config file claims. Without a declaration
        /// there is no key to join on, and the process name is not one.
        case unidentifiedProcess
        /// Identified, but its client's transcripts are not in the folders
        /// Sundown reads — so this corpus structurally cannot contain its
        /// calls, and a zero here would be an artefact.
        case transcriptsElsewhere(client: String)
        /// No tool traffic at all in the transcripts examined.
        case noToolTraffic
    }

    public struct Finding: Sendable, Hashable {
        public let record: ServerRecord
        /// Calls seen across the transcripts examined. Zero is the whole point.
        public let calls: Int
        public let abstention: Abstention?

        public var server: String { record.displayName }

        public init(record: ServerRecord, calls: Int, abstention: Abstention? = nil) {
            self.record = record
            self.calls = calls
            self.abstention = abstention
        }
    }

    /// Connected, and called at least once.
    public let used: [Finding]
    /// Connected, never called. The actionable list.
    public let idle: [Finding]
    /// Connected, but we decline to judge. Each carries its reason.
    public let unknown: [Finding]
    /// Declared in config with no process behind it. Costs nothing in context
    /// — and is probably not doing what its owner thinks it is.
    public let notRunning: [Finding]
    /// Measured standing charge for the whole set.
    public let fixedPrefixTokens: Int
    public let sessionsExamined: Int

    public init(
        used: [Finding],
        idle: [Finding],
        unknown: [Finding],
        notRunning: [Finding] = [],
        fixedPrefixTokens: Int,
        sessionsExamined: Int
    ) {
        self.used = used
        self.idle = idle
        self.unknown = unknown
        self.notRunning = notRunning
        self.fixedPrefixTokens = fixedPrefixTokens
        self.sessionsExamined = sessionsExamined
    }

    /// Servers actually running, which is what the standing charge buys.
    public var connectedCount: Int { used.count + idle.count + unknown.count }

    /// Share of the standing charge attributable to servers never called.
    ///
    /// Proportional split, and it is an estimate: the prefix also contains the
    /// system prompt, and servers differ enormously in schema size. Presented
    /// as an order of magnitude, never as a precise saving — see `report()`.
    public var estimatedIdleTokens: Int {
        guard connectedCount > 0, !idle.isEmpty else { return 0 }
        return fixedPrefixTokens / connectedCount * idle.count
    }

    /// How many more requests the same budget buys once the idle set is gone.
    ///
    /// Quota-independent on purpose. For any budget `B`, requests go from
    /// `B / prefix` to `B / (prefix - idle)`, and `B` cancels out of the ratio.
    /// That is the whole reason this can be answered offline: no plan, no
    /// account, no usage API, no network. Every tool that forecasts *when* you
    /// hit a limit needs all four.
    ///
    /// Inherits the proportional split in `estimatedIdleTokens`, so it is an
    /// order of magnitude and `report()` says so. `nil` when there is nothing
    /// to reclaim.
    public var requestHeadroomMultiplier: Double? {
        let remaining = fixedPrefixTokens - estimatedIdleTokens
        guard estimatedIdleTokens > 0, remaining > 0 else { return nil }
        return Double(fixedPrefixTokens) / Double(remaining)
    }
}

// MARK: - Building it

extension IdleServerReport {

    /// How many session files the *usage* half reads.
    ///
    /// Much deeper than the cost half, and the asymmetry is the point. The
    /// standing charge is a property of a request you would send now, so it is
    /// measured from recent sessions. "Never called" is a claim about history,
    /// and twelve files of one busy afternoon is not history — on the machine
    /// this was built against those twelve contained zero MCP calls, so every
    /// server abstained for want of evidence rather than for want of a name.
    /// Forty files was where the first real call traffic appeared.
    public static let usageHistoryLimit = 80

    /// - Parameters:
    ///   - servers: the current server set, keyed by config identity.
    ///   - registry: declarations, used to decide whether a client's
    ///     transcripts are present at all.
    ///   - metrics: measured transcript data, read deep — see
    ///     `usageHistoryLimit`.
    ///   - fixedPrefixTokens: today's standing charge, measured from recent
    ///     sessions rather than from the deep history. Defaults to the
    ///     history's own figure for callers that only have one reading.
    public static func build(
        servers: [ServerRecord],
        registry: MCPRegistry,
        metrics: TranscriptMetrics,
        fixedPrefixTokens: Int? = nil
    ) -> IdleServerReport {

        let calledIDs = Set(metrics.serverUsage.filter { $0.calls > 0 }.map(\.server))

        /// Whether this corpus could contain calls to this client's servers.
        ///
        /// The cross-client guard, made exact. Claude Desktop's servers do not
        /// appear in Claude Code's history, and calling them "never used" on
        /// that basis is not a near-miss — it is a confident accusation drawn
        /// from a corpus that structurally cannot hold the evidence.
        ///
        /// Tested against every declaration of the client rather than the ones
        /// currently running, so a client whose servers happen to all be idle
        /// is still judged rather than excused.
        func haveTranscripts(for client: String) -> Bool {
            registry.declarations.contains {
                $0.client == client && calledIDs.contains($0.transcriptID)
            }
        }

        var used: [Finding] = []
        var idle: [Finding] = []
        var unknown: [Finding] = []
        var notRunning: [Finding] = []

        // With no tool traffic at all there is no evidence about any server,
        // and saying "all idle" would be a confident lie.
        let haveEvidence = !metrics.serverUsage.isEmpty

        for record in servers.sorted(by: { $0.displayName < $1.displayName }) {
            guard record.state == .running else {
                notRunning.append(Finding(record: record, calls: 0))
                continue
            }

            guard let configKey = record.configKey else {
                unknown.append(
                    Finding(record: record, calls: 0, abstention: .unidentifiedProcess))
                continue
            }
            guard haveEvidence else {
                unknown.append(Finding(record: record, calls: 0, abstention: .noToolTraffic))
                continue
            }

            let client = configKey.split(separator: "/").first.map(String.init) ?? "?"
            guard haveTranscripts(for: client) else {
                unknown.append(
                    Finding(
                        record: record, calls: 0,
                        abstention: .transcriptsElsewhere(client: client)))
                continue
            }

            let calls = record.calls ?? 0
            if calls > 0 {
                used.append(Finding(record: record, calls: calls))
            } else {
                idle.append(Finding(record: record, calls: 0))
            }
        }

        return IdleServerReport(
            used: used.sorted { $0.calls > $1.calls },
            idle: idle,
            unknown: unknown,
            notRunning: notRunning,
            fixedPrefixTokens: fixedPrefixTokens ?? metrics.fixedPrefixTokens,
            sessionsExamined: metrics.sessionCount
        )
    }
}

// MARK: - Saying it

extension IdleServerReport {

    public func report() -> [String] {
        guard connectedCount > 0 else {
            return ["No MCP servers are currently running."]
        }

        var lines: [String] = []

        if !idle.isEmpty {
            lines.append(
                "\(idle.count) of \(connectedCount) connected servers were never called"
                    + " across \(sessionsExamined) session\(sessionsExamined == 1 ? "" : "s"):"
            )
            lines.append("")
            for finding in idle {
                lines.append("  · \(finding.server)")
            }
            if estimatedIdleTokens > 0 {
                lines.append("")
                lines.append(
                    "  They still load on every request — roughly "
                        + "\(estimatedIdleTokens.formatted()) tokens of your "
                        + "\(fixedPrefixTokens.formatted())-token standing charge."
                )
                if let multiplier = requestHeadroomMultiplier {
                    let percent = Int(((multiplier - 1) * 100).rounded())
                    lines.append(
                        "  Disconnecting them buys roughly \(percent)% more requests"
                            + " per window, on any plan."
                    )
                }
                lines.append(
                    "  Rough because the prefix includes the system prompt and schemas"
                )
                lines.append(
                    "  vary wildly. Use --snapshot / --compare to measure one exactly."
                )
            }
        } else if !used.isEmpty {
            lines.append(
                "All \(used.count) connected servers were called at least once. Nothing obviously wasted."
            )
        }

        if !used.isEmpty {
            lines.append("")
            lines.append("  Earning their place:")
            for finding in used.prefix(8) {
                lines.append(
                    "    \(finding.server) — \(finding.calls) call"
                        + "\(finding.calls == 1 ? "" : "s")"
                )
            }
        }

        if !notRunning.isEmpty {
            lines.append("")
            lines.append(
                "  Declared but not running: "
                    + notRunning.map(\.server).joined(separator: ", "))
            lines.append(
                "  They cost nothing right now. Worth knowing if you expected them to")
            lines.append(
                "  work — Sundown sees that no process is there, not whether that is a")
            lines.append("  failed start or a deliberate one.")
        }

        // Abstentions, grouped by *why*. The reason is the useful part: "their
        // process name doesn't match" is a shrug, "this client's transcripts
        // live somewhere Sundown isn't reading" is a thing you can go fix.
        if !unknown.isEmpty {
            let unidentified = unknown.filter { $0.abstention == .unidentifiedProcess }
            let elsewhere = unknown.filter {
                if case .transcriptsElsewhere = $0.abstention { return true }
                return false
            }
            let quiet = unknown.filter { $0.abstention == .noToolTraffic }

            if !unidentified.isEmpty {
                lines.append("")
                lines.append(
                    "  Not judged — no config declaration matches "
                        + "\(unidentified.count) running process"
                        + "\(unidentified.count == 1 ? "" : "es") "
                        + "(\(unidentified.map(\.server).joined(separator: ", "))).")
                lines.append(
                    "  Nothing in your MCP config spawns that command line, so there is no")
                lines.append(
                    "  server id to look for in the transcripts. Usually a plugin host")
                lines.append("  that launches servers from its own private directory.")
            }

            let clients = Set(
                elsewhere.compactMap { finding -> String? in
                    if case .transcriptsElsewhere(let client) = finding.abstention {
                        return client
                    }
                    return nil
                })
            if !elsewhere.isEmpty {
                lines.append("")
                lines.append(
                    "  Not judged — \(elsewhere.count) server"
                        + "\(elsewhere.count == 1 ? "" : "s") belong to "
                        + clients.sorted().joined(separator: ", ")
                        + ", whose transcripts")
                lines.append(
                    "  aren't in the folders Sundown reads: "
                        + elsewhere.map(\.server).joined(separator: ", ") + ".")
                lines.append(
                    "  Their calls cannot appear in this history, so a zero here would be")
                lines.append("  an artefact of where the history lives.")
            }

            if !quiet.isEmpty {
                lines.append("")
                lines.append(
                    "  Not judged — no tool traffic at all in the transcripts examined "
                        + "(\(quiet.count) server\(quiet.count == 1 ? "" : "s")).")
            }

            lines.append("")
            lines.append("  Not counted as idle — a wrong accusation costs more than a miss.")
        }

        return lines
    }
}
