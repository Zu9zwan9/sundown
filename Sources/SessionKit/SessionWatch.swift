import Foundation

/// Notices that an agent session ended, without being told.
///
/// Hooks are the obvious way to do this and they cannot do the important half.
/// A `SessionEnd` hook runs when the agent exits cleanly — which is exactly the
/// case where the agent already reaped most of its own children. The leftovers
/// that matter come from the other path: a crash, a force-quit, a closed
/// terminal. No handler runs there, by definition.
///
/// So this works by observation instead. Record which agent processes were
/// alive; on the next look, any that vanished ended a session. That covers
/// clean and unclean exits identically, because it never asks the agent
/// anything.
///
/// The cost is that it is edge-triggered on polling rather than on the event,
/// so the report arrives a poll interval late. For "you left something running"
/// that is fine. It would not be fine for anything time-critical, which this
/// isn't.
public struct SessionWatch: Codable, Sendable, Hashable {

    /// One agent process, identified strongly enough to survive PID reuse.
    public struct SeenAgent: Codable, Sendable, Hashable {
        public let pid: Int32
        public let providerID: String
        public let title: String
        /// Process start time.
        ///
        /// Load-bearing, not decorative: macOS recycles PIDs, and on a busy
        /// machine the wrap-around is measured in hours. Matching on PID alone
        /// would eventually see a fresh unrelated process wearing a dead
        /// agent's number and conclude the session never ended — silently, and
        /// only on the machines that leak most.
        public let startedAt: Date

        public init(pid: Int32, providerID: String, title: String, startedAt: Date) {
            self.pid = pid
            self.providerID = providerID
            self.title = title
            self.startedAt = startedAt
        }

        /// Same process, not merely the same number.
        ///
        /// Start times come from `proc_pidinfo` and round-trip through JSON, so
        /// they are compared with a tolerance rather than for equality.
        public func isSameProcess(as other: SeenAgent) -> Bool {
            pid == other.pid
                && abs(startedAt.timeIntervalSince(other.startedAt)) < 2
        }
    }

    public let agents: [SeenAgent]
    public let recordedAt: Date

    public init(agents: [SeenAgent], recordedAt: Date = Date()) {
        self.agents = agents
        self.recordedAt = recordedAt
    }
}

// MARK: - Persistence

extension SessionWatch {

    public static var storeURL: URL {
        let base =
            ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map {
                URL(fileURLWithPath: $0)
            }
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
        return base.appendingPathComponent("sundown/watch.json")
    }

    public static func save(_ watch: SessionWatch, to url: URL? = nil) throws {
        let target = url ?? storeURL
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(watch).write(to: target, options: .atomic)
    }

    public static func load(from url: URL? = nil) -> SessionWatch? {
        let source = url ?? storeURL
        guard let data = try? Data(contentsOf: source) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionWatch.self, from: data)
    }
}

// MARK: - The event

/// An agent session that ended and left something behind.
public struct SessionEndEvent: Sendable {

    /// Agents that were alive at the last look and are gone now.
    public let endedAgents: [SessionWatch.SeenAgent]
    /// What they left running, already filtered to things worth acting on.
    public let leftovers: [Target]

    public init(endedAgents: [SessionWatch.SeenAgent], leftovers: [Target]) {
        self.endedAgents = endedAgents
        self.leftovers = leftovers
    }

    public var reclaimableBytes: UInt64 {
        leftovers.reduce(0) { $0 + $1.residentBytes }
    }

    public var providerNames: [String] {
        var seen = Set<String>()
        return endedAgents.compactMap { agent in
            guard seen.insert(agent.providerID).inserted else { return nil }
            return Provider.known.first { $0.id == agent.providerID }?.name
                ?? agent.providerID
        }
    }

    /// One line, because that is all a notification gets.
    public var headline: String {
        let who = providerNames.joined(separator: " and ")
        let count = leftovers.count
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(reclaimableBytes), countStyle: .memory)
        return "\(who) finished — \(count) leftover\(count == 1 ? "" : "s"), \(size)"
    }
}

// MARK: - Detection

extension SessionWatch {

    /// Compare a previous look against the current one.
    ///
    /// Pure, so the interesting cases are testable without spawning agents and
    /// killing them.
    ///
    /// - Parameters:
    ///   - previous: the last recorded watch, or nil on first run.
    ///   - currentAgents: agent processes alive right now.
    ///   - leftovers: what the caller considers worth acting on. Passing the
    ///     phase-filtered selection keeps the policy in one place rather than
    ///     duplicating eligibility rules here.
    /// - Returns: nil when there is nothing worth saying.
    public static func detect(
        previous: SessionWatch?,
        currentAgents: [SeenAgent],
        leftovers: [Target]
    ) -> SessionEndEvent? {
        // First run has no baseline. Reporting every agent that isn't running
        // as "just ended" would open with a false alarm, which is the worst
        // possible first impression for something that offers to kill things.
        guard let previous else { return nil }

        let ended = previous.agents.filter { before in
            !currentAgents.contains { $0.isSameProcess(as: before) }
        }
        guard !ended.isEmpty else { return nil }

        // An agent that exited and left nothing behind is a success story, not
        // a notification. Staying quiet here is what makes the tool tolerable
        // to leave running.
        let attributable = leftovers.filter { target in
            ended.contains { $0.providerID == target.provider.id }
        }
        guard !attributable.isEmpty else { return nil }

        return SessionEndEvent(endedAgents: ended, leftovers: attributable)
    }

    /// Build a watch from the raw process table.
    ///
    /// **Observation and termination are governed separately, and this is the
    /// line between them.** `Safety` decides what may be signalled, and one of
    /// its refusals is anything inside a `.app` bundle. That rule is right —
    /// nothing here should be killing GUI applications.
    ///
    /// But Claude Code ships as `claude.app/Contents/MacOS/claude`, so applying
    /// the same rule to *watching* made the agent invisible: the watch tracked
    /// zero agents on a machine that was running one, and could therefore never
    /// fire. Found by checking the recorded baseline rather than trusting that
    /// the feature worked.
    ///
    /// Watching a process costs it nothing. Only the reaper consults `Safety`.
    public static func fromProcessTable(
        _ table: [pid_t: ProcessSnapshot],
        now: Date = Date()
    ) -> SessionWatch {
        SessionWatch(
            agents: table.values.compactMap { process in
                guard let provider = provider(for: process) else { return nil }
                return SeenAgent(
                    pid: process.pid,
                    providerID: provider.id,
                    title: process.executable,
                    startedAt: process.startedAt
                )
            },
            recordedAt: now
        )
    }

    /// Resolve a provider using the whole path, not just the executable name.
    ///
    /// Anthropic ships two different products whose binary is called `claude`:
    ///
    ///   /Applications/Claude.app/Contents/MacOS/Claude          — Claude Desktop
    ///   …/claude-code/2.1.229/claude.app/Contents/MacOS/claude  — Claude Code
    ///
    /// `Provider.fromExecutable` sees only the last component, so both resolve
    /// to Claude Code. Harmless in the target list, where the config join
    /// corrects it — but the watch names the provider in a notification, and
    /// announcing "Claude Code finished" when someone quit Claude Desktop is
    /// the kind of small wrongness that makes people distrust the big numbers.
    ///
    /// Special-cased rather than generalised: there is exactly one collision,
    /// and a framework for it would be more code than the problem.
    ///
    /// The match is on the **exact main-binary path**. A first attempt used
    /// `contains("/Applications/Claude.app/")` and picked up all 54 Electron
    /// helpers — renderers, plugin hosts, `chrome_crashpad_handler`, a process
    /// literally called `disclaimer`. Electron recycles those constantly, so
    /// the watch would have announced a finished session every few minutes.
    /// An app ends when its main process ends; helpers dying means nothing.
    static func provider(for process: ProcessSnapshot) -> Provider? {
        let path = process.arguments.first ?? ""

        if path.hasSuffix("/Applications/Claude.app/Contents/MacOS/Claude") {
            return .claudeDesktop
        }
        // Any other binary inside that bundle is a helper. Not an agent, and
        // emphatically not a session.
        if path.contains("/Applications/Claude.app/") { return nil }

        return Provider.fromExecutable(process.executable)
    }

    /// Build a watch from already-classified targets.
    public static func from(agents: [Target], now: Date = Date()) -> SessionWatch {
        SessionWatch(
            agents: agents.compactMap { target in
                guard case .process(let pid) = target.handle else { return nil }
                return SeenAgent(
                    pid: pid,
                    providerID: target.provider.id,
                    title: target.title,
                    // No start time means no defence against PID reuse. Using
                    // a fixed sentinel makes both sides compare equal, which
                    // degrades to PID-only matching — and that fails toward
                    // "still running", i.e. a missed report rather than a
                    // false one. Given the report offers to kill things, that
                    // is the direction to fail in.
                    startedAt: target.startedAt ?? .distantPast
                )
            },
            recordedAt: now
        )
    }
}
