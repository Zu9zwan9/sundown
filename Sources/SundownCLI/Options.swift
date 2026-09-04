import Foundation
import SessionKit

/// Hand-rolled argument parsing, on purpose.
///
/// This binary gets wired into shell hooks and launchd jobs where it runs
/// unattended with permission to end processes. Zero dependencies means zero
/// supply chain for the thing holding the knife.
struct Options {

    var phase: SessionPolicy.Phase = .after
    var provider: String?
    /// Overrides the never-touch-a-live-session default. The user checking the
    /// box themselves, which the policy has always allowed — there was just no
    /// way to say it from a command line.
    var includeInUse = false
    var dryRun = false
    var assumeYes = false
    var json = false
    var quiet = false
    var grace: Duration = .seconds(3)

    /// Act only if the selected targets hold at least this much memory.
    /// Exists so a launchd job can run every fifteen minutes and stay silent
    /// until there is actually something worth reclaiming.
    var minimumBytes: UInt64 = 0
    /// Report what connected MCP servers cost in context tokens per request.
    var showContext = false
    var tokensPerServer = ContextCost.defaultTokensPerServer
    /// Watch for a session ending; say nothing unless one did.
    var watch = false
    /// Which connected servers are never actually called.
    var showIdle = false
    /// Record today's standing charge and server set, to diff against later.
    var takeSnapshot = false
    /// Diff the current standing charge against the last snapshot.
    var compareSnapshot = false

    enum Action {
        case run
        case help
        case version
        case listProviders
        case calibrate
        case selfTest
    }
    var action: Action = .run

    static let usage = """
        sundown — what your agent sessions cost you, and what they left running

        USAGE
          sundown [options]

        WHAT NOTHING ELSE DOES
          --idle                         Which connected servers you never
                                           actually call. Joins the live
                                           process table against your session
                                           transcripts; abstains, loudly, on
                                           anything it cannot identify.
          --snapshot                     Record today's standing charge and
                                           server set. Never ends anything.
          --compare                      Diff against that baseline, using only
                                           sessions since it was taken. This is
                                           how you learn what one server costs.

        END WHAT A SESSION LEFT RUNNING
          (no options)                   List what's still running, end it on
                                           confirmation. Anything owned by a
                                           live session is never selected.
          --phase <before|during|after>  When you're running this. Default: after.
                                           before  Clear leftovers from earlier
                                                   sessions, including stray ports.
                                           during  Only orphans, duplicate servers,
                                                   and processes burning CPU.
                                           after   End what your session started.
          --provider <id>                Limit to one tool. See --list-providers.
          --include-in-use               Also end processes belonging to a running
                                           session. Off by default: if the owning
                                           app is still alive, ending its servers
                                           breaks it.
          -n, --dry-run                  Print what would be ended. Changes nothing.
          -y, --yes                      Skip confirmation. Required when not on a TTY.
          --grace <seconds>              Time given to exit before SIGKILL. Default: 3.
          --if-memory-above <size>       Do nothing unless the selection holds at
                                           least this much (e.g. 2GB, 500MB). For
                                           launchd jobs that should stay quiet
                                           until it's worth acting.
          --watch                        Report only if a session ended since the
                                           last run and left something behind.
                                           Silent otherwise, so it is safe on a
                                           timer. Exits 10 when it has something
                                           to say.

        YOUR AGENT MAY ALREADY SHOW YOU THIS
          --context                      What your servers cost in context per
                                           request, measured from transcripts.
                                           Claude Code's /context reports the
                                           same standing charge by category.
          --tokens-per-server <n>        Override the fallback estimate. Ignored
                                           when there are transcripts to measure.
          --calibrate                    When and how the estimate is used, and
                                           why measuring beats it.

        OTHER
          --json                         Machine-readable output.
          -q, --quiet                    Errors only.
          --list-providers               Print known provider ids.
          --self-test                    Check the config-to-transcript join on
                                           this machine. Exits 1 if it broke.
          -h, --help                     This.
          --version                      Version.

        EXIT CODES
          0  Nothing to do, or everything ended cleanly.
          1  One or more targets could not be ended.
          2  Bad usage.

        EXAMPLES
          sundown --idle                        Servers you pay for and never call.
          sundown --snapshot                    Mark a baseline before changing servers.
          sundown --compare                     What that change actually cost.
          sundown --dry-run                     See what a teardown would end.
          sundown --phase during                Kill a runaway without losing the session.
          sundown --provider claude-code -y     End only Claude Code's leftovers, no prompt.
          sundown --phase before -y --quiet     Preflight, for a shell hook.
          sundown --if-memory-above 2GB -y      Only act when 2GB+ is reclaimable.
        """

    /// Throws a human message rather than a stack trace. Everything a user
    /// gets wrong here is a typo, and a typo deserves a sentence.
    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = arguments.startIndex

        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.endIndex else {
                throw CLIError.usage("\(flag) needs a value")
            }
            return arguments[index]
        }

        while index < arguments.endIndex {
            switch arguments[index] {
            case "--phase":
                let raw = try next("--phase")
                guard let phase = SessionPolicy.Phase(rawValue: raw) else {
                    throw CLIError.usage(
                        "unknown phase '\(raw)' — expected before, during, or after"
                    )
                }
                options.phase = phase

            case "--provider":
                options.provider = try next("--provider")

            case "--grace":
                let raw = try next("--grace")
                guard let seconds = Double(raw), seconds >= 0, seconds <= 120 else {
                    throw CLIError.usage("--grace expects 0–120 seconds, got '\(raw)'")
                }
                options.grace = .milliseconds(Int(seconds * 1000))

            case "--if-memory-above":
                let raw = try next("--if-memory-above")
                guard let bytes = Options.parseSize(raw) else {
                    throw CLIError.usage(
                        "--if-memory-above expects a size like 2GB or 500MB, got '\(raw)'"
                    )
                }
                options.minimumBytes = bytes

            case "--tokens-per-server":
                let raw = try next("--tokens-per-server")
                guard let value = Int(raw), value > 0, value < 100_000 else {
                    throw CLIError.usage("--tokens-per-server expects 1–99999, got '\(raw)'")
                }
                options.tokensPerServer = value

            case "--context": options.showContext = true
            case "--watch": options.watch = true
            case "--idle":
                options.showIdle = true
                options.dryRun = true  // a report, never an action
            case "--snapshot":
                options.takeSnapshot = true
                options.dryRun = true  // recording a baseline must never end anything
            case "--compare":
                options.compareSnapshot = true
                options.dryRun = true
            case "--include-in-use": options.includeInUse = true
            case "-n", "--dry-run": options.dryRun = true
            case "-y", "--yes": options.assumeYes = true
            case "--json": options.json = true
            case "-q", "--quiet": options.quiet = true
            case "--list-providers": options.action = .listProviders
            case "--calibrate": options.action = .calibrate
            case "--self-test": options.action = .selfTest
            case "-h", "--help": options.action = .help
            case "--version": options.action = .version

            case let unknown:
                throw CLIError.usage("unknown option '\(unknown)' — try --help")
            }
            index += 1
        }

        if let id = options.provider,
            !Provider.known.contains(where: { $0.id == id })
        {
            throw CLIError.usage(
                "unknown provider '\(id)' — try --list-providers"
            )
        }
        return options
    }
}

extension Options {
    /// `2GB`, `500MB`, `1.5gb`, or a plain byte count.
    static func parseSize(_ raw: String) -> UInt64? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        // Shifts are Int; the multiplier is Double so "1.5gb" works. Converting
        // at the point of construction keeps the powers of two readable —
        // spelling 1_099_511_627_776 out is how a typo hides.
        let units: [(suffix: String, multiplier: Double)] = [
            ("tb", Double(1 << 40)), ("gb", Double(1 << 30)),
            ("mb", Double(1 << 20)), ("kb", Double(1 << 10)),
            ("g", Double(1 << 30)), ("m", Double(1 << 20)),
            ("k", Double(1 << 10)), ("b", 1),
        ]
        for (suffix, multiplier) in units where text.hasSuffix(suffix) {
            guard let value = Double(text.dropLast(suffix.count)), value >= 0 else { return nil }
            let bytes = value * multiplier
            // A threshold larger than addressable memory is a typo, not a
            // request. Converting an out-of-range Double to UInt64 traps, so
            // this guard is load-bearing rather than decorative.
            guard bytes.isFinite, bytes <= Double(UInt64.max) else { return nil }
            return UInt64(bytes)
        }
        guard let plain = Double(text), plain >= 0, plain.isFinite,
            plain <= Double(UInt64.max)
        else { return nil }
        return UInt64(plain)
    }
}

enum CLIError: Error {
    case usage(String)
}
