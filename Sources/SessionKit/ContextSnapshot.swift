import Foundation

/// A recorded "what it cost, with these servers connected" marker.
///
/// This is how Sundown answers *"what does this specific server cost me?"* —
/// the one question the aggregate measurement can't. Transcripts record token
/// counts but not which servers were connected, so the fixed prefix arrives as
/// a single undifferentiated number.
///
/// Rather than guess at a split, or spawn servers to interrogate them (which
/// has side effects — some connect to production systems on startup), this
/// turns the user's own behaviour into the experiment:
///
///   1. `sundown --snapshot`  — records today's prefix and server set
///   2. disconnect a server
///   3. `sundown --compare`   — reads only sessions since step 1, reports the delta
///
/// Exact, nothing spawned, and the number comes from the user's real workload
/// rather than a synthetic probe.
public struct ContextSnapshot: Codable, Sendable, Hashable {

    /// 1 stored `servers` as display strings, one per *process*. It could not
    /// be joined to anything and it counted four `pdf` processes as four
    /// servers. 2 stores identified records.
    public static let currentSchema = 2

    public let takenAt: Date
    /// Measured standing charge at the time of the snapshot.
    public let fixedPrefixTokens: Int
    /// Servers running when it was taken, sorted for stable diffing.
    public let servers: [ServerRecord]
    public let turnsObserved: Int
    public let schemaVersion: Int

    /// True when this was read from a v1 file and migrated in memory.
    ///
    /// Carried so the report can qualify what it says rather than presenting
    /// migrated data as if it had been recorded properly. Not encoded — a
    /// saved snapshot is always current-schema.
    public let migrated: Bool

    public init(
        takenAt: Date,
        fixedPrefixTokens: Int,
        servers: [ServerRecord],
        turnsObserved: Int,
        migrated: Bool = false
    ) {
        self.takenAt = takenAt
        self.fixedPrefixTokens = fixedPrefixTokens
        self.servers = servers.sorted { $0.diffKey < $1.diffKey }
        self.turnsObserved = turnsObserved
        self.schemaVersion = Self.currentSchema
        self.migrated = migrated
    }

    /// Running servers only. The standing charge is paid by these and nothing
    /// else, so this is what a count or a diff should ever be based on.
    public var running: [ServerRecord] { servers.filter { $0.state == .running } }

    // MARK: - Reading older files

    enum CodingKeys: String, CodingKey {
        case takenAt, fixedPrefixTokens, servers, turnsObserved, schemaVersion
    }

    /// Migrates v1 rather than refusing it.
    ///
    /// Refusing would have been easier and would have thrown away the only
    /// thing in the file that was always correct: the token figures. What v1
    /// got wrong was the server *list* — process-shaped, duplicated — so that
    /// is what migration marks as untrustworthy, by deduplicating the names it
    /// has and flagging the result. Nothing is invented: a migrated row has no
    /// config key, and every judgement that needs one abstains on it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        takenAt = try container.decode(Date.self, forKey: .takenAt)
        fixedPrefixTokens = try container.decode(Int.self, forKey: .fixedPrefixTokens)
        turnsObserved = try container.decode(Int.self, forKey: .turnsObserved)

        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        schemaVersion = Self.currentSchema

        if version >= 2 {
            servers = try container.decode([ServerRecord].self, forKey: .servers)
            migrated = false
        } else {
            let names = try container.decode([String].self, forKey: .servers)
            // Distinct, because the duplicates were never distinct servers.
            servers = Set(names).sorted().map {
                ServerRecord(id: $0, configKey: nil, argv: "", pids: [])
            }
            migrated = true
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(takenAt, forKey: .takenAt)
        try container.encode(fixedPrefixTokens, forKey: .fixedPrefixTokens)
        try container.encode(servers, forKey: .servers)
        try container.encode(turnsObserved, forKey: .turnsObserved)
        try container.encode(Self.currentSchema, forKey: .schemaVersion)
    }
}

// MARK: - Where it lives

extension ContextSnapshot {

    public static var storeURL: URL {
        let base =
            ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map {
                URL(fileURLWithPath: $0)
            }
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
        return base.appendingPathComponent("sundown/snapshot.json")
    }

    public static func save(_ snapshot: ContextSnapshot, to url: URL? = nil) throws {
        let target = url ?? storeURL
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: target, options: .atomic)
    }

    /// Why this reports its failure instead of returning nil: a file that
    /// exists and cannot be read is a different situation from no file, and
    /// the caller has to be able to say so. Silently treating a corrupt
    /// snapshot as "take a new one" would throw away the baseline the user is
    /// asking about.
    public enum LoadFailure: Error, Sendable {
        case missing
        case unreadable(String)
    }

    public static func load(from url: URL? = nil) throws -> ContextSnapshot {
        let source = url ?? storeURL
        guard let data = try? Data(contentsOf: source) else { throw LoadFailure.missing }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ContextSnapshot.self, from: data)
        } catch {
            throw LoadFailure.unreadable(String(describing: error))
        }
    }
}

// MARK: - The comparison

/// What changed between a snapshot and now.
public struct ContextComparison: Sendable {
    public let before: ContextSnapshot
    public let afterPrefixTokens: Int
    public let afterServers: [ServerRecord]
    /// Turns recorded *after* the snapshot. Zero means nothing has happened yet.
    public let turnsSince: Int

    public init(
        before: ContextSnapshot,
        afterPrefixTokens: Int,
        afterServers: [ServerRecord],
        turnsSince: Int
    ) {
        self.before = before
        self.afterPrefixTokens = afterPrefixTokens
        self.afterServers = afterServers.sorted { $0.diffKey < $1.diffKey }
        self.turnsSince = turnsSince
    }

    private var beforeRunning: Set<String> { Set(before.running.map(\.diffKey)) }
    private var afterRunningRecords: [ServerRecord] {
        afterServers.filter { $0.state == .running }
    }
    private var afterRunning: Set<String> { Set(afterRunningRecords.map(\.diffKey)) }

    /// Running then, not running now, and no longer declared anywhere. This is
    /// the only kind of "removed" that means what the word implies.
    public var removed: [ServerRecord] {
        let stillDeclared = Set(afterServers.map(\.diffKey))
        return before.running.filter {
            !afterRunning.contains($0.diffKey) && !stillDeclared.contains($0.diffKey)
        }
    }

    /// Running then, declared now, no process.
    ///
    /// Kept apart from `removed` because the two call for opposite responses.
    /// A removed server is a cost you chose to stop paying. This one is a
    /// server you still think you have.
    public var stopped: [ServerRecord] {
        let notRunningNow = Set(
            afterServers.filter { $0.state == .declaredNotRunning }.map(\.diffKey))
        return before.running.filter { notRunningNow.contains($0.diffKey) }
    }

    public var added: [ServerRecord] {
        afterRunningRecords.filter { !beforeRunning.contains($0.diffKey) }
    }

    /// Positive means the standing charge went down.
    public var tokensSaved: Int { before.fixedPrefixTokens - afterPrefixTokens }

    /// Whether there is enough new data to say anything at all.
    ///
    /// Disconnecting a server changes nothing that Sundown can see until a new
    /// session runs — the measurement comes from transcripts, and transcripts
    /// only exist once you've used the thing. Reporting a delta of zero here
    /// would read as "that server was free", which is the opposite of true.
    public var hasEnoughData: Bool { turnsSince > 0 }

    /// The one server the whole delta belongs to, when exactly one thing
    /// changed and the change moved the number the way that server would.
    ///
    /// Attribution is offered only when the experiment was clean. Two servers
    /// changed means two candidates and no way to separate them, which is a
    /// fact about the experiment rather than something to paper over with a
    /// division.
    public var attributable: (server: ServerRecord, tokens: Int)? {
        let changed = added + removed + stopped
        guard changed.count == 1, let only = changed.first, tokensSaved != 0 else { return nil }
        let gained = added.contains { $0.diffKey == only.diffKey }
        // A server that appeared should have raised the charge; one that left
        // should have lowered it. The opposite sign means something else moved
        // the number and this server is not the explanation.
        guard gained == (tokensSaved < 0) else { return nil }
        return (only, abs(tokensSaved))
    }

    public func report() -> [String] {
        let stamp = before.takenAt.formatted(date: .abbreviated, time: .shortened)

        guard hasEnoughData else {
            return [
                "Snapshot taken \(stamp) — \(before.fixedPrefixTokens.formatted()) tokens,",
                "\(before.running.count) servers.",
                "",
                "No sessions have run since. Disconnecting a server doesn't change",
                "anything measurable until you use the agent again — start a session,",
                "then re-run `sundown --compare`.",
            ]
        }

        var lines = [
            "Since \(stamp), across \(turnsSince.formatted()) new turns:",
            "",
            "  before: \(before.fixedPrefixTokens.formatted()) tokens  "
                + "(\(before.running.count) servers)",
            "  now:    \(afterPrefixTokens.formatted()) tokens  "
                + "(\(afterRunningRecords.count) servers)",
        ]

        if tokensSaved > 0 {
            lines.append("  saved:  \(tokensSaved.formatted()) tokens on every request")
        } else if tokensSaved < 0 {
            lines.append("  cost:   \((-tokensSaved).formatted()) more tokens on every request")
        } else {
            lines.append("  change: none")
        }

        if let (server, tokens) = attributable {
            lines.append("")
            lines.append("  → \(server.displayName) accounts for ~\(tokens.formatted()) of that:")
            lines.append("    it is the only server that changed between the two readings.")
        }

        // Before the lists, not after: it changes how they should be read.
        if before.migrated {
            lines.append("")
            lines.append(
                "  The baseline predates server identity — it stored one entry per")
            lines.append(
                "  process, so its count is deduplicated names and the lists below")
            lines.append(
                "  compare names against config keys. One server can appear in both,")
            lines.append(
                "  under its old process name and its real one. Token figures are")
            lines.append("  unaffected; re-run --snapshot for a clean baseline.")
        }

        if !removed.isEmpty {
            lines.append("")
            lines.append("  removed: \(removed.map(\.displayName).joined(separator: ", "))")
            if tokensSaved > 0, removed.count > 1, attributable == nil {
                lines.append(
                    "  → ~\((tokensSaved / removed.count).formatted()) tokens each on average; "
                        + "remove them one at a time to separate them"
                )
            }
        }
        if !stopped.isEmpty {
            lines.append("")
            lines.append(
                "  still declared, not running: "
                    + stopped.map(\.displayName).joined(separator: ", "))
            lines.append(
                "  Not removed — the config still lists them, so they cost nothing right")
            lines.append(
                "  now and you may be expecting them to work. Sundown can see that no")
            lines.append(
                "  process is there; it cannot see whether that is a crash or a choice.")
        }
        if !added.isEmpty {
            lines.append("")
            lines.append("  added:   \(added.map(\.displayName).joined(separator: ", "))")
        }

        lines.append("")
        lines.append(
            "  Coincidence, not proof: agent updates and different tool sets move")
        lines.append(
            "  this number too. One server at a time gives the cleanest reading.")

        return lines
    }
}
