import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One MCP server, keyed by what the user declared rather than by what the
/// kernel called the process that runs it.
///
/// The distinction is the whole file. A process name is not an identity: four
/// `pdf` processes are one server started four times, and `node` is not a name
/// at all. Worse, a process name cannot be joined to anything — a transcript
/// records `mcp__<id>__<tool>`, and no amount of string handling turns `pdf`
/// into `plugin_aws-startup-advisor_awspricing`. Keying by the config
/// declaration fixes the count and supplies the join in the same move.
public struct ServerRecord: Codable, Sendable, Hashable, Identifiable {

    /// What the process table proves about this server *right now*.
    ///
    /// Three states were previously one. `--compare` reported "removed:
    /// prisma mcp, prisma mcp" for a server that was still in the config and
    /// simply not connected — which reads as "you saved that cost" when the
    /// truth was closer to "the thing you rely on is not running".
    public enum State: String, Codable, Sendable {
        /// A process is running it. The only state that costs context.
        case running
        /// Declared in a config file, no process. Either it failed to start or
        /// the client has not started it — Sundown cannot tell which, and says
        /// so rather than picking one.
        case declaredNotRunning
    }

    /// The id this server's tools carry in transcripts — the `<id>` in
    /// `mcp__<id>__<tool>`. For a process we could not match to any
    /// declaration this falls back to the display name, which is not a join
    /// key and is never treated as one.
    public let id: String
    /// `Client/name`, straight from the config file. Nil means unidentified,
    /// and every downstream judgement abstains on it.
    public let configKey: String?
    public let argv: String
    /// Every process running this one declaration. Duplicates live here — that
    /// is the bug fix: they are instances, not servers.
    public let pids: [pid_t]

    /// Tokens of tool-result payload charged to this server across the
    /// transcripts examined — measured, attributed exactly by the `mcp__`
    /// prefix, and *not* a share of the standing charge, which cannot be split
    /// from outside. Nil when we hold no transcripts that could say.
    public let tokens: Int?
    /// Calls seen. Nil and zero mean different things: nil is "no evidence",
    /// zero is "evidence, and it was never called". Collapsing them is how a
    /// tool accuses someone of not using a server it simply cannot see.
    public let calls: Int?
    public let state: State

    public init(
        id: String,
        configKey: String?,
        argv: String,
        pids: [pid_t],
        tokens: Int? = nil,
        calls: Int? = nil,
        state: State = .running
    ) {
        self.id = id
        self.configKey = configKey
        self.argv = argv
        self.pids = pids
        self.tokens = tokens
        self.calls = calls
        self.state = state
    }

    /// The key two snapshots are diffed on. Config identity where we have one;
    /// otherwise the display name, marked as such so a diff of unidentified
    /// rows can never be confused with a diff of real servers.
    public var diffKey: String { configKey ?? "process:\(id)" }
    public var isIdentified: Bool { configKey != nil }

    /// The bare name, for output. `Claude Code/plugin:aws:pricing` → the last
    /// component the user would recognise.
    public var displayName: String {
        guard let key = configKey else { return id }
        return key.split(separator: "/").dropFirst().joined(separator: "/")
    }
}

// MARK: - The join

extension ServerRecord {

    /// Credentials, out of a file people paste into bug reports.
    ///
    /// A snapshot now stores command lines, and command lines carry secrets:
    /// the first real one written on the machine this was built against held a
    /// live `secret=` in an MCP server's URL. The snapshot is meant to be
    /// shared — it is the evidence in "this server costs me 12k tokens" — so
    /// the redaction belongs here, at the point of capture, not at the point
    /// of display where one forgotten call site leaks it.
    ///
    /// Conservative on purpose: it masks values for keys that name a secret,
    /// and leaves everything else legible. A command line you cannot read
    /// identifies nothing.
    static func redacted(_ argv: String) -> String {
        let patterns = [
            #"(?i)\b(secret|token|api[-_]?key|apikey|password|passwd|auth|access[-_]?key|pat)"#
                + #"(\s*[=:]\s*)([^\s&"']+)"#,
            #"(?i)\b(bearer)(\s+)([A-Za-z0-9._\-]{8,})"#,
        ]
        var result = argv
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            result = expression.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1$2[redacted]"
            )
        }
        return result
    }

    /// Build the current server set from the three things that have to agree:
    /// the process table, the config, and the transcripts.
    ///
    /// - Parameters:
    ///   - targets: MCP-server targets from the scan.
    ///   - table: the raw process table, for argv.
    ///   - registry: declarations read from every config we know about.
    ///   - metrics: transcript measurements, or nil when there are none.
    ///   - agentClients: names of clients with a live agent process. A stdio
    ///     server only exists while its client is running, so "declared but
    ///     not running" is meaningless — and alarming — for a client that
    ///     isn't open.
    public static func build(
        targets: [Target],
        table: [pid_t: ProcessSnapshot],
        registry: MCPRegistry,
        metrics: TranscriptMetrics?,
        agentClients: Set<String> = []
    ) -> [ServerRecord] {

        let usage = Dictionary(
            (metrics?.serverUsage ?? []).map { ($0.server, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Group processes by declaration. This is the deduplication: four
        // processes running one declared server produce one record with four
        // pids, not four records.
        var pidsByKey: [String: [pid_t]] = [:]
        var argvByKey: [String: String] = [:]

        for target in targets {
            guard case .process(let pid) = target.handle else { continue }
            let key = target.declarationKey ?? "process:\(target.title)"
            pidsByKey[key, default: []].append(pid)
            // Longest argv wins: a wrapper and the server it exec'd share a
            // declaration, and the fuller command line is the informative one.
            let argv = redacted(table[pid]?.commandLine ?? target.title)
            if argv.count > (argvByKey[key]?.count ?? 0) { argvByKey[key] = argv }
        }

        var records: [ServerRecord] = []

        for (key, pids) in pidsByKey {
            let declaration = registry.declaration(identity: key)
            let transcriptID = declaration?.transcriptID
            let seen = transcriptID.flatMap { usage[$0] }

            records.append(
                ServerRecord(
                    id: transcriptID ?? key.replacingOccurrences(of: "process:", with: ""),
                    configKey: declaration != nil ? key : nil,
                    argv: argvByKey[key] ?? "",
                    pids: pids.sorted(),
                    // No declaration means no join key, so no attribution —
                    // not zero, which would read as "cost you nothing".
                    tokens: declaration == nil ? nil : (seen?.approximateTokens ?? 0),
                    calls: declaration == nil ? nil : (seen?.calls ?? 0),
                    state: .running
                )
            )
        }

        // Declared and not running. Only for clients we can see are open, and
        // only for stdio servers — a remote server has no process to miss, so
        // its absence from the table proves precisely nothing.
        let runningKeys = Set(records.compactMap(\.configKey))
        let liveClients =
            agentClients.union(
                records.compactMap(\.configKey).compactMap {
                    $0.split(separator: "/").first.map(String.init)
                })

        for declaration in registry.declarations
        where declaration.transport == .stdio
            && !runningKeys.contains(declaration.identity)
            && liveClients.contains(declaration.client)
        {
            records.append(
                ServerRecord(
                    id: declaration.transcriptID,
                    configKey: declaration.identity,
                    argv: redacted(declaration.fingerprint ?? ""),
                    pids: [],
                    tokens: nil,
                    calls: usage[declaration.transcriptID]?.calls,
                    state: .declaredNotRunning
                )
            )
        }

        return records.sorted { $0.diffKey < $1.diffKey }
    }
}
