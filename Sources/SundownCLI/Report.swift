import Foundation
import SessionKit

/// The `--json` contract. Kept as explicit DTOs rather than encoding domain
/// types directly, so a refactor inside SessionKit can't silently break
/// somebody's script.
struct Report: Encodable {

    struct Item: Encodable {
        let id: String
        let title: String
        let kind: String
        let provider: String
        let providerName: String
        let pid: Int32?
        let containerID: String?
        let residentBytes: UInt64
        let cpuPercent: Double
        let ageSeconds: Int?
        let orphaned: Bool
        let superseded: Bool
        let inUse: Bool
        let selected: Bool
        let reason: String
        let evidence: String

        init(target: Target, selected: Bool, reason: String, now: Date) {
            self.id = target.id
            self.title = target.title
            self.kind = target.kind.rawValue
            self.provider = target.provider.id
            self.providerName = target.provider.name
            switch target.handle {
            case .process(let pid): self.pid = pid; self.containerID = nil
            case .container(let cid): self.pid = nil; self.containerID = cid
            }
            self.residentBytes = target.residentBytes
            self.cpuPercent = (target.cpuPercent * 10).rounded() / 10
            self.ageSeconds = target.startedAt.map { Int(now.timeIntervalSince($0)) }
            self.orphaned = target.isOrphaned
            self.superseded = target.isSuperseded
            self.inUse = target.hasLiveOwner
            self.selected = selected
            self.reason = reason
            self.evidence = target.evidence
        }
    }

    struct Result: Encodable {
        let id: String
        let title: String
        let outcome: String
        let detail: String?
        let reclaimedBytes: UInt64

        init(_ outcome: Outcome) {
            self.id = outcome.id
            self.title = outcome.title
            self.reclaimedBytes = outcome.reclaimedBytes
            switch outcome.result {
            case .exitedOnRequest: self.outcome = "exited"; self.detail = nil
            case .forced: self.outcome = "forced"; self.detail = nil
            case .alreadyGone: self.outcome = "gone"; self.detail = nil
            case .refused(let d): self.outcome = "refused"; self.detail = d
            case .failed(let d): self.outcome = "failed"; self.detail = d
            }
        }
    }

    struct Summary: Encodable {
        let found: Int
        let selected: Int
        let reclaimableBytes: UInt64
        /// False until two scans have been differenced. Runaway detection is
        /// not meaningful while this is false, and saying so beats implying
        /// every process is idle.
        let cpuRatesAvailable: Bool
    }

    let phase: String
    let dryRun: Bool
    let scannedAt: String
    let summary: Summary
    let items: [Item]
    let results: [Result]?

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func encoded() -> String {
        guard let data = try? Self.encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Human output

enum Console {

    static func bytes(_ value: UInt64) -> String {
        guard value > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func write(_ line: String = "") {
        print(line)
    }

    static func error(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// A row, aligned so a long list scans vertically.
    ///
    /// Age earns a column because it's the number that makes someone act:
    /// "6h 12m" is the time you spent not knowing this was running.
    static func row(_ item: Report.Item) -> String {
        let mark = item.selected ? "✔" : " "
        let name =
            item.title.count > 26
            ? String(item.title.prefix(25)) + "…"
            : item.title.padding(toLength: 26, withPad: " ", startingAt: 0)
        let size = bytes(item.residentBytes).leftPadded(to: 9)
        let age =
            item.ageSeconds
            .map { duration(seconds: $0).leftPadded(to: 7) } ?? String(repeating: " ", count: 7)
        let cpu =
            item.cpuPercent >= 1
            ? "\(Int(item.cpuPercent))%".leftPadded(to: 5)
            : "     "
        return "  \(mark) \(name) \(size) \(age) \(cpu)  \(item.reason)"
    }

    static func duration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
