import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Assembles one view of "what this session left running".
///
/// Everything here is a read. Nothing is signalled, stopped, or changed —
/// scanning and ending are separate operations on purpose, so the list the
/// user approves is the list that gets acted on.
public struct SessionScan: Sendable {
    public let targets: [Target]
    public let table: [pid_t: ProcessSnapshot]
    public let lineage: Set<pid_t>
    public let scannedAt: Date
    /// False on the very first scan, before there are two CPU samples to
    /// difference. Runaway detection is meaningless until this is true.
    public let hasCPURates: Bool

    public var reclaimableBytes: UInt64 {
        targets.reduce(0) { $0 + $1.residentBytes }
    }
}

/// An actor so scanning runs off the main thread by construction, and so the
/// caches and the CPU baseline below have somewhere safe to live.
public actor SessionScanner {

    private let source: any ProcessSource
    private let classifier = Classifier()
    private let ports = PortScanner()
    private let containers = ContainerScanner()

    /// `lsof` and `docker ps` each fork a process. Running them on every
    /// refresh meant two process spawns every few seconds for data that
    /// changes far more slowly than the process table does.
    private static let shellTTL: Duration = .seconds(20)
    private var listenerCache: (value: [PortScanner.Listener], at: ContinuousClock.Instant)?
    private var containerCache: (value: [ContainerScanner.Container], at: ContinuousClock.Instant)?

    /// Config files are hand-edited and change on the order of weeks.
    private static let registryTTL: Duration = .seconds(60)
    private var registryCache: (value: MCPRegistry, at: ContinuousClock.Instant)?

    /// Previous cumulative CPU per pid, for computing a rate.
    private var cpuBaseline: [pid_t: UInt64] = [:]
    private var cpuBaselineAt: ContinuousClock.Instant?

    public init(source: any ProcessSource) {
        self.source = source
    }

    #if canImport(Darwin)
    public init() {
        self.source = DarwinProcessSource()
    }
    #endif

    /// Forces the next scan to re-run the shell probes. Call after ending a
    /// session, when ports and containers genuinely have changed.
    public func invalidateShellCaches() {
        listenerCache = nil
        containerCache = nil
    }

    // MARK: - Cached probes

    private func currentListeners() -> [PortScanner.Listener] {
        if let cache = listenerCache, ContinuousClock.now - cache.at < Self.shellTTL {
            return cache.value
        }
        let fresh = ports.scan()
        listenerCache = (fresh, ContinuousClock.now)
        return fresh
    }

    private func currentContainers() -> [ContainerScanner.Container] {
        if let cache = containerCache, ContinuousClock.now - cache.at < Self.shellTTL {
            return cache.value
        }
        let fresh = containers.scan()
        containerCache = (fresh, ContinuousClock.now)
        return fresh
    }

    private func currentRegistry() -> MCPRegistry {
        if let cache = registryCache, ContinuousClock.now - cache.at < Self.registryTTL {
            return cache.value
        }
        let fresh = MCPRegistry.fromDisk()
        registryCache = (fresh, ContinuousClock.now)
        return fresh
    }

    /// CPU as a percentage of one core, from the delta since the last scan.
    ///
    /// Returns empty on the first call — there is nothing to difference — and
    /// on any interval too short to be meaningful. An empty result is honest;
    /// a fabricated 0% would read as "idle" and it isn't.
    private func cpuRates(for processes: [ProcessSnapshot]) -> [pid_t: Double] {
        let now = ContinuousClock.now
        let previous = cpuBaseline
        let previousAt = cpuBaselineAt

        cpuBaseline = Dictionary(
            processes.map { ($0.pid, $0.cpuNanoseconds) },
            uniquingKeysWith: { first, _ in first }
        )
        cpuBaselineAt = now

        guard let previousAt else { return [:] }
        let elapsed = now - previousAt
        let seconds =
            Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        guard seconds >= 0.5 else { return [:] }

        var rates: [pid_t: Double] = [:]
        for process in processes {
            // A missing baseline means the process is new since the last scan;
            // a smaller value means pid reuse. Both are "unknown", not zero.
            guard let before = previous[process.pid],
                process.cpuNanoseconds >= before
            else { continue }
            let burned = Double(process.cpuNanoseconds - before) / 1e9
            rates[process.pid] = burned / seconds * 100
        }
        return rates
    }

    // MARK: - Scan

    public func scan() -> SessionScan {
        let processes = source.snapshot()
        let table = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let lineage = SafetyGuard.lineage(in: table)
        let guardrail = SafetyGuard(ownLineage: lineage)

        var children: [pid_t: [pid_t]] = [:]
        for process in processes {
            children[process.parentPID, default: []].append(process.pid)
        }

        let rates = cpuRates(for: processes)
        let registry = currentRegistry()

        // Classify first, so subtree collection knows where to stop.
        var matches: [pid_t: Classifier.Match] = [:]
        var declarations: [pid_t: MCPRegistry.Declaration] = [:]
        // Declarations borrowed from an ancestor, tracked apart because they
        // name a link in a chain rather than an instance of a server.
        var borrowed: Set<pid_t> = []

        for process in processes {
            guard case .allowed = guardrail.verdict(for: process) else { continue }

            // A config match beats every heuristic: the user wrote this server
            // down by name. It also catches servers whose command line carries
            // no hint of MCP at all, which the classifier cannot see.
            if let declaration = registry.declaration(matching: process) {
                matches[process.pid] = Classifier.Match(
                    kind: .mcpServer,
                    confidence: .certain,
                    evidence: "Declared in \(declaration.client)"
                )
                declarations[process.pid] = declaration
            } else if let match = classifier.classify(process) {
                matches[process.pid] = match

                // The classifier can see a server here but cannot name it: the
                // command the user declared belongs to an ancestor, and the
                // wrapper chain below it carries no trace. Naming it is the
                // difference between a row reading `node` and one that joins
                // to transcript history.
                if let ancestral = registry.declaration(matching: process, in: table) {
                    declarations[process.pid] = ancestral
                    borrowed.insert(process.pid)
                }
            }
        }

        // Names and owners are resolved once, here, because duplicate
        // detection needs both before any Target exists.
        var names: [pid_t: String] = [:]
        var owners: [pid_t: Provider] = [:]
        for (pid, match) in matches {
            guard let process = table[pid] else { continue }
            owners[pid] = provider(for: process, table: table, registry: registry)
            names[pid] =
                declarations[pid]?.name
                ?? (match.kind == .agent
                    ? process.executable
                    : Classifier.displayName(for: process))
        }

        let superseded = supersededPIDs(
            declarations: declarations, borrowed: borrowed,
            names: names, owners: owners, table: table
        )
        let listeners = currentListeners()
        let portsByPID = Dictionary(grouping: listeners, by: \.pid)
            .mapValues { $0.map(\.port).sorted() }

        // A classified process nested under another classified process keeps
        // its own row — an MCP server under a running agent is still a thing
        // the user recognises by name.
        var targets: [Target] = []
        var claimed: Set<pid_t> = []

        for (pid, match) in matches {
            guard let process = table[pid] else { continue }
            let subtree = descendants(of: pid, in: children, stoppingAt: Set(matches.keys))
            claimed.formUnion(subtree)

            let subtreeBytes = subtree.reduce(process.residentBytes) { total, child in
                total + (table[child]?.residentBytes ?? 0)
            }
            let subtreeCPU = subtree.reduce(rates[pid] ?? 0) { total, child in
                total + (rates[child] ?? 0)
            }
            let heldPorts = ([pid] + subtree).flatMap { portsByPID[$0] ?? [] }.sorted()

            targets.append(
                makeTarget(
                    process: process,
                    match: match,
                    declaration: declarations[pid],
                    name: names[pid] ?? process.executable,
                    provider: owners[pid] ?? .unattributed,
                    hasLiveOwner: hasLiveOwner(process, table: table),
                    isSuperseded: superseded.contains(pid),
                    cpuPercent: subtreeCPU,
                    subtree: subtree,
                    bytes: subtreeBytes,
                    ports: heldPorts
                )
            )
        }

        // Listening ports nobody claimed: a dev server or watcher that outlived
        // whatever started it. Surfaced, never preselected.
        for listener in listeners
        where !claimed.contains(listener.pid) && matches[listener.pid] == nil {
            guard let process = table[listener.pid],
                case .allowed = guardrail.verdict(for: process)
            else { continue }
            targets.append(
                Target(
                    id: "port-\(listener.port)",
                    handle: .process(listener.pid),
                    kind: .listener,
                    title: "\(listener.command) · :\(listener.port)",
                    subtitle: subtitle(for: process, lead: listener.command),
                    evidence: "Listening on port \(listener.port)",
                    provider: provider(for: process, table: table, registry: registry),
                    residentBytes: process.residentBytes,
                    cpuPercent: rates[listener.pid] ?? 0,
                    startedAt: process.startedAt,
                    confidence: .probable,
                    isOrphaned: process.parentPID == 1,
                    hasLiveOwner: hasLiveOwner(process, table: table),
                    descendants: descendants(
                        of: listener.pid, in: children, stoppingAt: Set(matches.keys)),
                    ports: [listener.port]
                )
            )
        }

        for container in currentContainers() {
            targets.append(
                Target(
                    id: "container-\(container.id)",
                    handle: .container(id: container.id),
                    kind: .container,
                    title: container.name,
                    subtitle: "\(container.image) · \(container.status.lowercased())",
                    evidence: container.isEphemeral
                        ? "Development container"
                        : "Running container",
                    confidence: container.isEphemeral ? .certain : .probable
                )
            )
        }

        return SessionScan(
            targets: targets.sorted(by: ordering),
            table: table,
            lineage: lineage,
            scannedAt: Date(),
            hasCPURates: !rates.isEmpty
        )
    }

    // MARK: - Attribution

    /// Which tool this process belongs to.
    ///
    /// Order matters. The config declaration wins because it survives
    /// orphaning — once a process is reparented to launchd, its ancestry is
    /// gone and the declaration is the only evidence left of whose it was.
    private func provider(
        for process: ProcessSnapshot,
        table: [pid_t: ProcessSnapshot],
        registry: MCPRegistry
    ) -> Provider {
        if let declaration = registry.declaration(matching: process) {
            let named = Provider.named(declaration.client)
            if named != .unattributed { return named }
        }
        if let own = identity(of: process) { return own }

        var cursor = process.parentPID
        for _ in 0..<64 {
            guard cursor > 1, let ancestor = table[cursor] else { break }
            if let found = identity(of: ancestor) { return found }
            cursor = ancestor.parentPID
        }
        return .unattributed
    }

    /// Whether a *living, identified* ancestor exists.
    ///
    /// Starts at the parent, never at the process itself: a running agent CLI
    /// is the session, not something owned by one, and must stay endable.
    private func hasLiveOwner(_ process: ProcessSnapshot, table: [pid_t: ProcessSnapshot]) -> Bool {
        var cursor = process.parentPID
        for _ in 0..<64 {
            guard cursor > 1, let ancestor = table[cursor] else { return false }
            if identity(of: ancestor) != nil { return true }
            cursor = ancestor.parentPID
        }
        return false
    }

    private func identity(of process: ProcessSnapshot) -> Provider? {
        if let path = process.arguments.first,
            let bundle = Provider.fromBundlePath(path)
        {
            return bundle
        }
        return Provider.fromExecutable(process.executable)
    }

    /// Older instances of a server that is running more than once.
    ///
    /// This is the reported failure mode made visible: every session spawns a
    /// fresh copy, nothing cleans the old ones up, and you end up with six
    /// `filesystem` servers. Only the newest is doing anything.
    private func supersededPIDs(
        declarations: [pid_t: MCPRegistry.Declaration],
        borrowed: Set<pid_t>,
        names: [pid_t: String],
        owners: [pid_t: Provider],
        table: [pid_t: ProcessSnapshot]
    ) -> Set<pid_t> {

        /// A config declaration is the best identity. Without one, the whole
        /// command line is the identity — not just the name.
        ///
        /// The looser key (tool + name + binary) was wrong in a way that
        /// matters: two Cursor windows each serving a different folder are two
        /// `filesystem` servers that are both genuinely in use. Pairing them
        /// and calling the older one superseded would end a live window's
        /// server. Identical argv means identical invocation, which is the
        /// only case where one of the pair is provably redundant.
        func identity(_ pid: pid_t) -> String? {
            // A borrowed declaration names one link in a server's chain, not a
            // competing instance of it. Keying four chain links on the shared
            // name would call three of them redundant and offer to end them.
            if let declaration = declarations[pid], !borrowed.contains(pid) {
                return declaration.identity
            }
            guard let process = table[pid], !process.commandLine.isEmpty else { return nil }
            return "\(owners[pid]?.id ?? "?")\u{1F}\(process.commandLine)"
        }

        var newest: [String: (pid: pid_t, at: Date)] = [:]
        for pid in names.keys {
            guard let key = identity(pid), let started = table[pid]?.startedAt else { continue }
            if let existing = newest[key], existing.at >= started { continue }
            newest[key] = (pid, started)
        }

        return Set(
            names.keys.filter { pid in
                guard let key = identity(pid) else { return false }
                return newest[key]?.pid != pid
            }
        )
    }

    // MARK: - Assembly

    private func makeTarget(
        process: ProcessSnapshot,
        match: Classifier.Match,
        declaration: MCPRegistry.Declaration?,
        name: String,
        provider: Provider,
        hasLiveOwner: Bool,
        isSuperseded: Bool,
        cpuPercent: Double,
        subtree: [pid_t],
        bytes: UInt64,
        ports: [UInt16]
    ) -> Target {
        let orphaned = process.parentPID == 1

        // The pid lives here rather than in the subtitle. It's the least
        // useful thing on a row you're deciding about and the widest, and it
        // was pushing the age off the end of the line.
        var evidence = "\(match.evidence) · pid \(process.pid)"
        if orphaned { evidence += " · reparented to launchd" }
        if isSuperseded { evidence += " · superseded by a newer instance" }

        return Target(
            id: "pid-\(process.pid)",
            handle: .process(process.pid),
            kind: match.kind,
            title: name,
            // What it's pointed at beats what it's written in. "~/Documents"
            // identifies which filesystem server this is; "node" does not.
            subtitle: subtitle(
                for: process,
                lead: declaration?.scope ?? process.executable,
                childCount: subtree.count,
                ports: ports
            ),
            evidence: evidence,
            provider: provider,
            residentBytes: bytes,
            cpuPercent: cpuPercent,
            startedAt: process.startedAt,
            confidence: match.confidence,
            isOrphaned: orphaned,
            hasLiveOwner: hasLiveOwner,
            isSuperseded: isSuperseded,
            declarationKey: declaration?.identity,
            descendants: subtree,
            ports: ports
        )
    }

    private func subtitle(
        for process: ProcessSnapshot,
        lead: String,
        childCount: Int = 0,
        ports: [UInt16] = []
    ) -> String {
        var parts = [lead]
        if childCount == 1 { parts.append("1 child") }
        if childCount > 1 { parts.append("\(childCount) children") }
        if let port = ports.first { parts.append(":\(port)") }
        return parts.joined(separator: " · ")
    }

    /// Every descendant, breadth-first, excluding subtrees that were themselves
    /// classified — those are separate targets and own their own children.
    private func descendants(
        of root: pid_t,
        in children: [pid_t: [pid_t]],
        stoppingAt boundaries: Set<pid_t>
    ) -> [pid_t] {
        var collected: [pid_t] = []
        var queue = children[root] ?? []
        var visited: Set<pid_t> = [root]

        while let pid = queue.first {
            queue.removeFirst()
            guard visited.insert(pid).inserted else { continue }
            guard !boundaries.contains(pid) else { continue }
            collected.append(pid)
            queue.append(contentsOf: children[pid] ?? [])
        }
        return collected
    }

    /// Provider first, then the clearest leftovers, then heaviest.
    private func ordering(_ a: Target, _ b: Target) -> Bool {
        if a.provider != b.provider { return a.provider < b.provider }
        if a.kind != b.kind { return a.kind < b.kind }
        if a.isOrphaned != b.isOrphaned { return a.isOrphaned }
        if a.isSuperseded != b.isSuperseded { return a.isSuperseded }
        if a.residentBytes != b.residentBytes { return a.residentBytes > b.residentBytes }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}
