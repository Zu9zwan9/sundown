import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - What we found

/// A single thing Sundown can end.
public struct Target: Identifiable, Hashable, Sendable {

    public enum Handle: Hashable, Sendable {
        case process(pid_t)
        case container(id: String)
    }

    public let id: String
    public let handle: Handle
    public let kind: Kind

    /// Short, human name. "filesystem", "claude", "vite", "devcontainer-web".
    public let title: String
    /// Quiet second line. "node · pid 4821 · 2h 14m"
    public let subtitle: String

    /// Why this was flagged. Shown on hover. A tool that kills things
    /// owes the user its reasoning.
    public let evidence: String

    /// Which tool this belongs to. Drives grouping and per-provider cleanup.
    public let provider: Provider

    public let residentBytes: UInt64
    /// Recent CPU as a percentage of one core. Needs two scans to establish,
    /// so it reads 0 on the first pass — treat 0 as "not yet known", not idle.
    public let cpuPercent: Double
    public let startedAt: Date?
    public let confidence: Confidence

    /// Reparented to launchd — its client already quit and left it behind.
    public let isOrphaned: Bool
    /// A living ancestor we could attribute to a provider. False means either
    /// orphaned or spawned by something we couldn't identify — in both cases,
    /// ending it cannot interrupt a session we can see.
    public let hasLiveOwner: Bool
    /// Another process is running the same declared server, and started later.
    /// The classic symptom: each session spawns fresh servers, none clean up.
    public let isSuperseded: Bool
    /// Identity of the declaration this runs, when config-matched. The key
    /// duplicates are grouped by.
    public let declarationKey: String?

    /// Descendants that go with it. Ended first, leaves inward.
    public let descendants: [pid_t]
    /// Listening ports this target holds, if any.
    public let ports: [UInt16]

    public init(
        id: String,
        handle: Handle,
        kind: Kind,
        title: String,
        subtitle: String,
        evidence: String,
        provider: Provider = .unattributed,
        residentBytes: UInt64 = 0,
        cpuPercent: Double = 0,
        startedAt: Date? = nil,
        confidence: Confidence = .certain,
        isOrphaned: Bool = false,
        hasLiveOwner: Bool = false,
        isSuperseded: Bool = false,
        declarationKey: String? = nil,
        descendants: [pid_t] = [],
        ports: [UInt16] = []
    ) {
        self.id = id
        self.handle = handle
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.evidence = evidence
        self.provider = provider
        self.residentBytes = residentBytes
        self.cpuPercent = cpuPercent
        self.startedAt = startedAt
        self.confidence = confidence
        self.isOrphaned = isOrphaned
        self.hasLiveOwner = hasLiveOwner
        self.isSuperseded = isSuperseded
        self.declarationKey = declarationKey
        self.descendants = descendants
        self.ports = ports
    }
}

public enum Kind: String, CaseIterable, Sendable, Comparable {
    case mcpServer
    case agent
    case container
    case listener

    /// Display order. Most-certainly-yours first.
    private var rank: Int {
        switch self {
        case .mcpServer: 0
        case .agent: 1
        case .container: 2
        case .listener: 3
        }
    }

    public static func < (a: Kind, b: Kind) -> Bool { a.rank < b.rank }
}

/// How sure we are. `.probable` items are not selected by default —
/// the user opts in, never out, of ambiguity.
public enum Confidence: Sendable, Hashable {
    case certain
    case probable
}

// MARK: - What happened

public struct Outcome: Identifiable, Sendable, Hashable {
    public enum Result: Sendable, Hashable {
        case exitedOnRequest  // took SIGTERM and left politely
        case forced  // needed SIGKILL
        case alreadyGone  // won the race, fine
        case refused(String)  // safety guard said no
        case failed(String)
    }

    public let id: String
    public let title: String
    public let result: Result
    public let reclaimedBytes: UInt64

    public var succeeded: Bool {
        switch result {
        case .exitedOnRequest, .forced, .alreadyGone: true
        case .refused, .failed: false
        }
    }
}

// MARK: - Raw process facts

public struct ProcessSnapshot: Identifiable, Hashable, Sendable {
    public let pid: pid_t
    public let parentPID: pid_t
    public let userID: uid_t
    /// Kernel-reported name. Truncated to 32 chars by the OS.
    public let name: String
    /// Full argv. Empty when the process denied us a read.
    public let arguments: [String]
    public let startedAt: Date
    public let residentBytes: UInt64
    /// Cumulative CPU time consumed, in nanoseconds. Differencing two
    /// snapshots gives a rate; a single reading is meaningless on its own.
    public let cpuNanoseconds: UInt64

    public var id: pid_t { pid }
    public var commandLine: String { arguments.joined(separator: " ") }

    /// argv[0] reduced to its last path component, lowercased.
    public var executable: String {
        guard let first = arguments.first, !first.isEmpty else { return name.lowercased() }
        return (first.split(separator: "/").last.map(String.init) ?? first).lowercased()
    }

    public init(
        pid: pid_t, parentPID: pid_t, userID: uid_t, name: String,
        arguments: [String], startedAt: Date, residentBytes: UInt64,
        cpuNanoseconds: UInt64 = 0
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.userID = userID
        self.name = name
        self.arguments = arguments
        self.startedAt = startedAt
        self.residentBytes = residentBytes
        self.cpuNanoseconds = cpuNanoseconds
    }
}

/// The one seam that has to be reimplemented to leave macOS.
public protocol ProcessSource: Sendable {
    func snapshot() -> [ProcessSnapshot]
}
