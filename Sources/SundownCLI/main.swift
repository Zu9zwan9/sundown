import Foundation
import SessionKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let version = "0.1.0"

// MARK: - Parse

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch CLIError.usage(let message) {
    Console.error("sundown: \(message)")
    exit(2)
} catch {
    // Top-level code is not a throwing context, so this has to be exhaustive.
    Console.error("sundown: \(error.localizedDescription)")
    exit(2)
}

switch options.action {
case .help:
    Console.write(Options.usage)
    exit(0)
case .version:
    Console.write("sundown \(version)")
    exit(0)
case .listProviders:
    for provider in Provider.known {
        Console.write(
            "\(provider.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(provider.name)")
    }
    exit(0)
case .calibrate:
    Console.write(ContextCost.calibrationInstructions)
    exit(0)
case .selfTest:
    let (lines, passed) = SelfTest.run()
    for line in lines { Console.write(line) }
    exit(passed ? 0 : 1)
case .run:
    break
}

// MARK: - Scan

let scanner = SessionScanner()
let policy = SessionPolicy()

// CPU is a rate, so it needs two samples. Only `during` acts on it, so only
// `during` pays the second-and-a-bit it costs.
var scan = await scanner.scan()
if options.phase == .during {
    try? await Task.sleep(for: .milliseconds(1100))
    scan = await scanner.scan()
}

let now = scan.scannedAt

// Read the config once. It is the join key for everything below: a process
// tells you a command line, a transcript tells you `mcp__<id>__<tool>`, and
// only the declaration the user wrote knows both.
let registry = MCPRegistry.fromDisk()

/// Clients with a live agent. A stdio server exists only while its client
/// does, so "declared but not running" says something about a client that is
/// open and nothing at all about one that isn't.
let agentClients = Set(
    SessionWatch.fromProcessTable(scan.table, now: now).agents.compactMap { agent in
        Provider.known.first { $0.id == agent.providerID }?.name
    })

var eligible = scan.targets.filter { policy.isEligible($0, phase: options.phase) }
if let providerID = options.provider {
    eligible = eligible.filter { $0.provider.id == providerID }
}

var selectedIDs = Set(
    eligible.filter { policy.isPreselected($0, phase: options.phase) }.map(\.id)
)
if options.includeInUse {
    // The user overriding the invariant explicitly. Same phase rule, minus the
    // ownership guard — so the override can't select something the phase
    // wouldn't have wanted anyway.
    selectedIDs.formUnion(
        eligible
            .filter { $0.hasLiveOwner && policy.matchesPhaseRule($0, phase: options.phase) }
            .map(\.id)
    )
}
let selected = eligible.filter { selectedIDs.contains($0.id) }

let items = eligible.map {
    Report.Item(
        target: $0,
        selected: selectedIDs.contains($0.id),
        reason: policy.reason($0, phase: options.phase),
        now: now
    )
}
let reclaimable = selected.reduce(UInt64(0)) { $0 + $1.residentBytes }

/// The current server set, keyed by config identity rather than process name.
/// One record per declared server, however many processes are running it.
func currentServers(metrics: TranscriptMetrics?) -> [ServerRecord] {
    ServerRecord.build(
        targets: eligible.filter { $0.kind == .mcpServer },
        table: scan.table,
        registry: registry,
        metrics: metrics,
        agentClients: agentClients
    )
}

/// What to do about rows that weren't selected.
///
/// Every hint names a real flag. "None match the rule" tells the user what
/// happened; it doesn't tell them what to do about it, and that gap is the
/// difference between a tool that works and one that looks broken.
let hints: [String] = {
    var lines: [String] = []

    let inUse = eligible.filter(\.hasLiveOwner).count
    if inUse > 0 && !options.includeInUse {
        lines.append(
            "\(inUse) in use by a running session — quit the app, "
                + "or --include-in-use to end them anyway."
        )
    }

    let uncertain = eligible.filter { !$0.hasLiveOwner && $0.confidence == .probable }.count
    if uncertain > 0 && options.phase == .after {
        lines.append(
            "\(uncertain) uncertain — --phase before also takes stray ports "
                + "and idle containers."
        )
    }
    return lines
}()

func makeReport(results: [Outcome]?) -> Report {
    Report(
        phase: options.phase.rawValue,
        dryRun: options.dryRun,
        scannedAt: ISO8601DateFormatter().string(from: now),
        summary: .init(
            found: eligible.count,
            selected: selected.count,
            reclaimableBytes: reclaimable,
            cpuRatesAvailable: scan.hasCPURates
        ),
        items: items,
        results: results.map { $0.map(Report.Result.init) }
    )
}

// MARK: - Present
//
// Always show the list before deciding anything. An earlier version exited
// early when nothing was selected, which meant `--dry-run` found nine
// processes and printed none of them — a dry run that refuses to show you the
// run. Every row carries its own reason, so seeing them is the whole point.

if eligible.isEmpty {
    if options.json {
        Console.write(makeReport(results: []).encoded())
    } else if !options.quiet {
        Console.write("Nothing running from a session.")
    }
    exit(0)
}

// Context cost. Reported before the list, because it's the argument for
// acting at all: idle servers are not free, they tax every request you send.
// Session-end watch. Edge-triggered, and deliberately mute.
//
// This runs on a timer, so the default has to be silence. A cleanup tool that
// speaks up every fifteen minutes gets muted within a day, and then it is worth
// nothing at the moment it finally has something real to say.
//
// Three conditions, all required: an agent that was alive is now gone, it left
// something behind, and that something belongs to it.
if options.watch {
    // The raw table, not the target list. Agent CLIs that live inside a .app
    // bundle are excluded from targets on purpose — Sundown must never kill
    // one — but excluding them from *observation* made the watch blind to the
    // exact process whose exit it exists to notice.
    let agentsNow = SessionWatch.fromProcessTable(scan.table, now: now)
    let event = SessionWatch.detect(
        previous: SessionWatch.load(),
        currentAgents: agentsNow.agents,
        leftovers: selected
    )

    // Record the new baseline before anything can fail below, so a crash in
    // reporting can't make the same session end fire again on the next run.
    try? SessionWatch.save(agentsNow)

    guard let event else {
        if !options.quiet && !options.json {
            Console.write("Nothing ended since the last look.")
        }
        exit(0)
    }

    if options.json {
        Console.write(makeReport(results: []).encoded())
    } else {
        Console.write(event.headline)
        for target in event.leftovers.prefix(8) {
            Console.write(
                "  \(target.title) — "
                    + ByteCountFormatter.string(
                        fromByteCount: Int64(target.residentBytes), countStyle: .memory))
        }
        if event.leftovers.count > 8 {
            Console.write("  …and \(event.leftovers.count - 8) more")
        }
        Console.write()
        Console.write("  sundown --phase after -y    ends them")
        Console.write("  sundown --dry-run           shows the full list first")
    }

    // A distinct code so a launchd job or shell hook can branch on "there is
    // something to clean" without parsing stdout.
    exit(10)
}

// The join: what's connected, against what actually got called.
//
// Neither half is interesting alone — `/context` already prices what's loaded,
// and transcript readers already count what was used. Only a tool that reads
// the process table *and* the transcripts can say which servers you pay for
// and never touch, which is the only version of this that implies an action.
if options.showIdle && !options.json {
    // Two readings, deliberately. Recent sessions price a request you would
    // send now; deep history is what "never called" has to be measured
    // against, and the two windows are not the same window.
    let recent = TranscriptMetrics.load()
    let history = TranscriptMetrics.load(limit: IdleServerReport.usageHistoryLimit)
    let report = IdleServerReport.build(
        servers: currentServers(metrics: history),
        registry: registry,
        metrics: history,
        fixedPrefixTokens: recent.fixedPrefixTokens
    )
    for line in report.report() { Console.write(line.isEmpty ? "" : "  \(line)") }
    Console.write()
    exit(0)
}

// Snapshot / compare: the only way to learn what one specific server costs.
// Both are read-only by construction — Options forces --dry-run for either.
if options.takeSnapshot && !options.json {
    let measured = TranscriptMetrics.load()
    let snapshot = ContextSnapshot(
        takenAt: Date(),
        fixedPrefixTokens: measured.fixedPrefixTokens,
        servers: currentServers(metrics: measured),
        turnsObserved: measured.turns.count
    )
    do {
        try ContextSnapshot.save(snapshot)
        let running = snapshot.running
        let unidentified = running.filter { !$0.isIdentified }
        Console.write("Snapshot recorded")
        Console.write("  \(snapshot.fixedPrefixTokens.formatted()) tokens standing charge")
        Console.write(
            "  \(running.count) MCP server\(running.count == 1 ? "" : "s") running"
                + (running.count == running.reduce(0) { $0 + max($1.pids.count, 1) }
                    ? ""
                    : ", across "
                        + "\(running.reduce(0) { $0 + $1.pids.count }) processes"))
        if !unidentified.isEmpty {
            Console.write(
                "  \(unidentified.count) could not be matched to a config declaration —")
            Console.write("  they are recorded by process name and diffed as such.")
        }
        Console.write()
        Console.write("  Now disconnect a server, use the agent for a session or two,")
        Console.write("  then run: sundown --compare")
    } catch {
        Console.error("sundown: could not save snapshot — \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

if options.compareSnapshot && !options.json {
    let previous: ContextSnapshot
    do {
        previous = try ContextSnapshot.load()
    } catch ContextSnapshot.LoadFailure.missing {
        Console.error("sundown: no snapshot to compare against. Run `sundown --snapshot` first.")
        exit(1)
    } catch {
        // Loudly, and without reinterpreting it. A file we cannot parse is not
        // a baseline of zero servers; treating it as one would manufacture a
        // saving out of a read error.
        Console.error(
            "sundown: the snapshot at \(ContextSnapshot.storeURL.path) could not be read.")
        Console.error(
            "  It has not been reinterpreted under the current format — that would invent")
        Console.error("  a baseline. Run `sundown --snapshot` to record a new one.")
        exit(1)
    }
    // Only sessions since the snapshot say anything about the change.
    let after = TranscriptMetrics.load(since: previous.takenAt)
    let comparison = ContextComparison(
        before: previous,
        afterPrefixTokens: after.fixedPrefixTokens,
        afterServers: currentServers(metrics: after),
        turnsSince: after.turns.count
    )
    for line in comparison.report() { Console.write(line.isEmpty ? "" : "  \(line)") }
    exit(0)
}

if options.showContext && !options.json && !options.quiet {
    let mcpCount = eligible.filter { $0.kind == .mcpServer }.count

    // Measured beats estimated, every time. If this machine has transcripts,
    // report what actually happened; the multiply-a-constant model is the
    // fallback for when it doesn't, not the headline.
    let measured = TranscriptMetrics.load()
    if measured.isEmpty {
        let cost = ContextCost(serverCount: mcpCount, tokensPerServer: options.tokensPerServer)
        Console.write("Context cost (estimated)")
        for line in cost.explanation() { Console.write("  \(line)") }
    } else {
        Console.write("Context cost (measured)")
        for line in measured.explanation(serverCount: mcpCount) {
            Console.write(line.isEmpty ? "" : "  \(line)")
        }

        // The active half. Unlike the fixed prefix this attributes exactly,
        // because the server name is embedded in every MCP tool name.
        let byCost = measured.serversByCost
        if !byCost.isEmpty {
            Console.write()
            Console.write("  What using them cost, by server:")
            for usage in byCost.prefix(8) {
                let name = usage.server.padding(toLength: 24, withPad: " ", startingAt: 0)
                Console.write(
                    "    \(name) \(String(format: "%4d", usage.calls)) calls  "
                        + "~\(usage.approximateTokens.formatted()) tokens  "
                        + "(~\(usage.averageTokensPerCall.formatted())/call)"
                )
            }
            Console.write(
                "    Results are charged once, unlike the standing charge above.")
        }
    }
    Console.write()
}

if !options.json && !options.quiet {
    Console.write("\(options.phase.title) — \(options.phase.summary)")
    Console.write()

    var lastProvider: Provider?
    for (item, target) in zip(items, eligible) {
        if target.provider != lastProvider {
            Console.write(target.provider.name)
            lastProvider = target.provider
        }
        Console.write(Console.row(item))
    }
    Console.write()

    if selected.isEmpty {
        Console.write("Nothing selected.")
        for hint in hints { Console.write("  \(hint)") }
    } else {
        Console.write(
            "Ends \(selected.count) of \(eligible.count) · frees \(Console.bytes(reclaimable))"
        )
    }

    if options.phase == .during && !scan.hasCPURates {
        Console.write("CPU rates unavailable — runaway detection skipped this run.")
    }
}

if selected.isEmpty {
    if options.json { Console.write(makeReport(results: []).encoded()) }
    exit(0)
}

// Threshold gate. A scheduled job that fires every fifteen minutes should do
// nothing almost every time; this is what makes silence the default.
if reclaimable < options.minimumBytes {
    if options.json {
        Console.write(makeReport(results: []).encoded())
    } else if !options.quiet {
        Console.write(
            "Below threshold — \(Console.bytes(reclaimable)) reclaimable, "
                + "\(Console.bytes(options.minimumBytes)) required. Nothing ended."
        )
    }
    exit(0)
}

if options.dryRun {
    if options.json {
        Console.write(makeReport(results: nil).encoded())
    } else if !options.quiet {
        Console.write("Dry run. Nothing was ended.")
    }
    exit(0)
}

// MARK: - Confirm

if !options.assumeYes {
    // A hook that forgot `--yes` must neither hang on a prompt nobody will
    // answer nor quietly kill things. Refuse, and say exactly what to add.
    guard isatty(STDIN_FILENO) == 1 else {
        Console.error("sundown: refusing to end processes non-interactively without --yes")
        exit(2)
    }
    Console.write()
    FileHandle.standardOutput.write(Data("End \(selected.count)? [y/N] ".utf8))
    let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    guard answer == "y" || answer == "yes" else {
        Console.write("Cancelled.")
        exit(0)
    }
}

// MARK: - Act

let reaper = Reaper(
    guardrail: SafetyGuard(ownLineage: scan.lineage),
    table: scan.table
)
let outcomes = await reaper.end(selected, grace: options.grace)

let succeeded = outcomes.filter(\.succeeded)
let failed = outcomes.filter { !$0.succeeded }
let reclaimed = succeeded.reduce(UInt64(0)) { $0 + $1.reclaimedBytes }

if options.json {
    Console.write(makeReport(results: outcomes).encoded())
} else if !options.quiet {
    Console.write()
    Console.write("Ended \(succeeded.count) · \(Console.bytes(reclaimed)) reclaimed")
    for failure in failed {
        let detail: String =
            switch failure.result {
            case .refused(let why): why
            case .failed(let why): why
            default: "unknown"
            }
        Console.error("  could not end \(failure.title): \(detail)")
    }
}

exit(failed.isEmpty ? 0 : 1)
