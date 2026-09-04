import Foundation

/// What is safe to end, and when.
///
/// Cleaning up before you start work, while you're working, and after you
/// finish are three different problems with three different risk profiles.
/// Treating them as one — a single "kill everything" button — is how a
/// cleanup tool eats someone's live session and never gets opened again.
///
/// One invariant holds across all three phases: **anything with a living,
/// identified owner is never preselected.** If we can see the agent that
/// spawned it and that agent is still running, ending it interrupts a session
/// somebody is using. The user can always check the box themselves; we never
/// check it for them.
public struct SessionPolicy: Sendable {

    public enum Phase: String, CaseIterable, Sendable, Codable {
        /// Before you start. Nothing running is yours yet.
        case before
        /// Mid-session. Highest risk, narrowest scope.
        case during
        /// You're done. The default.
        case after

        public var title: String {
            switch self {
            case .before: "Preflight"
            case .during: "Triage"
            case .after: "Teardown"
            }
        }

        /// The button label. Says what happens, not what mode you're in.
        public var verb: String {
            switch self {
            case .before: "Clear Leftovers"
            case .during: "End Runaways"
            case .after: "End Session"
            }
        }

        public var summary: String {
            switch self {
            case .before:
                "Ends everything left from earlier sessions, including stray ports."
            case .during:
                "Only orphans, duplicate servers, and processes burning CPU."
            case .after:
                "Ends what your session started. Leaves long-lived services alone."
            }
        }
    }

    /// Sustained use of this fraction of a single core counts as a runaway.
    /// Fifty is deliberately well clear of the 1–2% an idle MCP server uses
    /// and well below the 100% that a spinning orphan pegs.
    public let runawayCPUPercent: Double

    public init(runawayCPUPercent: Double = 50) {
        self.runawayCPUPercent = runawayCPUPercent
    }

    // MARK: - Eligibility

    /// Whether a target is even shown in this phase.
    ///
    /// Only `.during` narrows the list, because it's the only phase where the
    /// user has work in flight that a mistake would destroy.
    public func isEligible(_ target: Target, phase: Phase) -> Bool {
        switch phase {
        case .before, .after:
            true
        case .during:
            target.isOrphaned || target.isSuperseded || isRunaway(target)
        }
    }

    public func isRunaway(_ target: Target) -> Bool {
        target.cpuPercent >= runawayCPUPercent
    }

    // MARK: - Default selection

    public func isPreselected(_ target: Target, phase: Phase) -> Bool {
        // Supersession outranks ownership, and this exception is load-bearing.
        //
        // Field data from a developer who instrumented their own machine for
        // eleven weeks: in 21 of 37 health checks the orphan count was zero
        // while the machine still exhausted memory — 797 processes, every one
        // with a living parent. The dominant failure is not abandonment, it's
        // the same server respawned per session and never reaped.
        //
        // Refusing to preselect those made the tool blind to the majority of
        // the actual problem. A superseded target ran an *identical* command
        // line to a newer sibling under the same tool, so the live owner is
        // talking to the newer one. Ending this copy cannot break the session.
        if target.isSuperseded { return matchesPhaseRule(target, phase: phase) }

        // Otherwise the invariant holds, in every phase, without exception.
        guard !target.hasLiveOwner else { return false }
        return matchesPhaseRule(target, phase: phase)
    }

    /// The phase's own rule with the in-use guard lifted.
    ///
    /// Exists for `sundown --include-in-use`, where the user is explicitly
    /// overriding the invariant. Keeping it as one method rather than a second
    /// copy of the rules means the override can't drift from the default.
    public func matchesPhaseRule(_ target: Target, phase: Phase) -> Bool {
        switch phase {
        case .before:
            // Nothing running predates only this session — it predates *you*.
            // Sweep wider: stray ports and idle containers included.
            return true

        case .during:
            // Only what is unambiguously a leftover. A runaway is shown but
            // left unchecked: this is the phase where being wrong costs most,
            // and "busy" is not the same as "abandoned".
            return target.isOrphaned || target.isSuperseded

        case .after:
            // The daily ritual. Certain matches only, so the Postgres you've
            // had up for three weeks survives the end of your workday.
            return target.confidence == .certain
        }
    }

    /// Everything this phase would end, given a scan.
    public func selection(from targets: [Target], phase: Phase) -> Set<Target.ID> {
        Set(
            targets
                .filter { isEligible($0, phase: phase) && isPreselected($0, phase: phase) }
                .map(\.id)
        )
    }

    // MARK: - Explanation

    /// Why this row is checked, unchecked, or present at all.
    ///
    /// Shown on hover in the panel and printed by `sundown --dry-run`. A tool
    /// with no undo has to be able to explain itself before it acts.
    public func reason(_ target: Target, phase: Phase) -> String {
        // Explain the decision, not merely the condition.
        //
        // This used to lead with `isSuperseded` unconditionally, which read
        // correctly right up until teardown — where the certain-match rule
        // also applies. Two rows then printed the identical sentence while one
        // was checked and the other wasn't, and the column that exists to
        // explain the checkbox was the one thing that couldn't. Deriving the
        // outcome first means the text cannot disagree with the box again.
        let selected = isEligible(target, phase: phase) && isPreselected(target, phase: phase)

        if target.isSuperseded {
            guard selected else {
                // Supersession alone always satisfies preselection, so the only
                // rule left that can reject it is teardown's certain-match
                // requirement.
                return "Superseded, but an uncertain match — check it yourself if you mean it"
            }
            return "Superseded — an identical newer instance is running"
        }
        if target.hasLiveOwner {
            return "In use by \(target.provider.name) — unchecked so a live session survives"
        }
        if target.isOrphaned {
            return selected
                ? "Orphaned — its client quit and left it running"
                : "Orphaned, but an uncertain match — check it yourself if you mean it"
        }
        if isRunaway(target) {
            return "Using \(Int(target.cpuPercent))% CPU"
        }

        switch phase {
        case .before:
            return "Left from an earlier session"
        case .during:
            return "Not a leftover — left alone during a session"
        case .after:
            return target.confidence == .certain
                ? "Started by \(target.provider.name)"
                : "Uncertain match — check it yourself if you mean it"
        }
    }
}
