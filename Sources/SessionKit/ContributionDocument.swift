import Foundation

/// What a machine can honestly say in public about what its MCP servers cost.
///
/// `--idle` answers "is this worth disconnecting" for one machine. It cannot
/// answer "what will this server cost me" for a machine that has not installed
/// it yet, and no registry answers that either — the official registry,
/// Smithery and mcpservers.org all list capability and no economics.
///
/// This is the smallest document that lets many machines answer it together.
///
/// ## Why it carries a total rather than a per-server split
///
/// `estimatedIdleTokens` divides the standing charge evenly across connected
/// servers, which is a proportional guess and says so. Shipping that guess as
/// data would launder an estimate into a citation.
///
/// So each submission carries the measured total and the exact set that
/// produced it. Given enough submissions with *different* sets, per-server cost
/// is recoverable by solving the system rather than guessing at it — the one
/// thing a single machine can never do, and the reason an index is worth more
/// than the sum of its rows.
///
/// ## Privacy
///
/// Server ids, call counts, a client name, a date. No paths, no project names,
/// no machine identifier, no message content. The binary never transmits this:
/// `--contribute` prints it and the person decides.
public struct ContributionDocument: Codable, Sendable, Equatable {

    public static let currentSchema = 1

    public struct Server: Codable, Sendable, Equatable {
        /// The bare id, as the registry names it and as the user typed it into
        /// their config. Heuristic display names are deliberately not used: a
        /// row nobody can look up is a row nobody can act on.
        public let id: String
        public let calls: Int

        public init(id: String, calls: Int) {
            self.id = id
            self.calls = calls
        }
    }

    public let schema: Int
    /// Day precision. An exact timestamp is a fingerprint and buys nothing.
    public let submittedAt: String
    /// The client whose transcripts produced this. `mixed` when a machine ran
    /// servers from more than one, which is a fact about the machine rather
    /// than a failure to decide.
    public let client: String
    public let sessionsExamined: Int
    /// Measured standing charge for the whole set below, in tokens.
    public let standingChargeTokens: Int
    /// Sorted by id, so the same set on two machines serialises identically.
    public let servers: [Server]

    public init(
        schema: Int = ContributionDocument.currentSchema,
        submittedAt: String,
        client: String,
        sessionsExamined: Int,
        standingChargeTokens: Int,
        servers: [Server]
    ) {
        self.schema = schema
        self.submittedAt = submittedAt
        self.client = client
        self.sessionsExamined = sessionsExamined
        self.standingChargeTokens = standingChargeTokens
        self.servers = servers.sorted { $0.id < $1.id }
    }
}

extension ContributionDocument {

    /// Build from a report, keeping only servers matched to a config
    /// declaration.
    ///
    /// Servers in `unknown` are excluded on purpose. Sundown abstains from
    /// judging them locally because it could not match them to a declaration,
    /// and a row it declined to judge for its owner has no business becoming
    /// evidence about somebody else.
    ///
    /// `nil` when there is nothing worth publishing. An empty submission is
    /// noise in a dataset whose only asset is that it can be trusted.
    public static func build(
        from report: IdleServerReport,
        on date: Date = Date()
    ) -> ContributionDocument? {
        var clients: Set<String> = []
        var servers: [Server] = []

        for finding in report.used + report.idle {
            guard let key = finding.record.configKey else { continue }
            // configKey is "<client>/<id>" — the same split IdleServerReport
            // uses to decide which transcripts may speak about a server.
            let parts = key.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { continue }
            clients.insert(String(parts[0]))
            servers.append(Server(id: String(parts[1]), calls: finding.calls))
        }

        guard !servers.isEmpty, report.fixedPrefixTokens > 0 else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        return ContributionDocument(
            submittedAt: formatter.string(from: date),
            client: clients.count == 1 ? clients.first! : "mixed",
            sessionsExamined: report.sessionsExamined,
            standingChargeTokens: report.fixedPrefixTokens,
            servers: servers
        )
    }

    /// Pretty, sorted and stable, because the first thing the person does with
    /// it is read it and decide whether to publish it.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
