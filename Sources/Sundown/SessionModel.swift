import Foundation
import Observation
import SessionKit

@MainActor
@Observable
final class SessionModel {

    enum Phase: Equatable {
        case idle
        case scanning
        case ending(done: Int, total: Int)
        /// Held briefly after a run so the result is readable, then released.
        case finished(ended: Int, reclaimed: UInt64, failures: [Outcome])
    }

    private(set) var targets: [Target] = []
    private(set) var phase: Phase = .idle
    private(set) var lastScan: Date?
    private(set) var hasCPURates = false

    /// Which lifecycle moment this is. Defaults to teardown — the daily case.
    /// The other two live in the menu rather than on a segmented control,
    /// because showing three modes to solve one problem is how a one-button
    /// utility turns into a settings screen.
    private(set) var lifecycle: SessionPolicy.Phase = .after

    /// Selection is explicit state, not derived, so a refresh can't silently
    /// re-check something the user deliberately unchecked.
    private(set) var selection: Set<Target.ID> = []

    /// What is being ended, in the exact order the reaper will take it.
    ///
    /// `Phase.ending(done:total:)` is a count, and a count can only ever
    /// become a progress bar. The panel needs *identity* — which row is going
    /// right now — because watching the work move down the list is what tells
    /// someone the tool is doing what they asked, on the things they picked.
    /// A spinner tells them only that something is happening somewhere.
    private(set) var endingOrder: [Target.ID] = []
    /// How many of `endingOrder` are finished. The reaper works sequentially,
    /// so this doubles as the index of the row currently in flight.
    private(set) var endedCount = 0

    private let policy = SessionPolicy()
    private var scan: SessionScan?
    private let scanner = SessionScanner()
    private var resultDismissal: Task<Void, Never>?

    // MARK: - Derived

    /// Only what this lifecycle phase is willing to touch.
    var eligible: [Target] {
        targets.filter { policy.isEligible($0, phase: lifecycle) }
    }

    /// Grouped by the tool that left it behind. "Claude Code left 6 behind"
    /// is actionable in a way that "6 MCP servers" is not.
    var groups: [(provider: Provider, targets: [Target])] {
        Dictionary(grouping: eligible, by: \.provider)
            .map { (provider: $0.key, targets: $0.value) }
            .sorted { $0.provider < $1.provider }
    }

    var selectedTargets: [Target] {
        eligible.filter { selection.contains($0.id) }
    }

    var reclaimableBytes: UInt64 {
        selectedTargets.reduce(0) { $0 + $1.residentBytes }
    }

    var isBusy: Bool {
        if case .ending = phase { return true }
        return false
    }

    /// Where a row sits in a run that is happening right now.
    enum EndState: Equatable {
        /// Not part of this run, or no run is under way.
        case untouched
        /// Chosen, waiting its turn.
        case queued
        /// The one the reaper has in hand.
        case inFlight
        /// Done. Stays on screen, resolved, until the confirming scan clears
        /// it — a row that vanished the instant we asked it to quit would be
        /// claiming a result we hadn't waited for.
        case ended
    }

    func endState(_ id: Target.ID) -> EndState {
        guard let index = endingOrder.firstIndex(of: id) else { return .untouched }
        if index < endedCount { return .ended }
        if index == endedCount, isBusy { return .inFlight }
        return isBusy ? .queued : .ended
    }

    /// The name of the row in the reaper's hands, for the line above the
    /// button. "Ending 3 of 7" is a count; "Ending playwright" is the thing
    /// the user actually wants confirmed while it happens.
    var endingNow: String? {
        guard isBusy, endedCount < endingOrder.count else { return nil }
        let id = endingOrder[endedCount]
        return targets.first { $0.id == id }?.title
    }

    func reason(for target: Target) -> String {
        policy.reason(target, phase: lifecycle)
    }

    /// One line under the title. States what is true, not what we're doing.
    var headline: String {
        switch phase {
        case .scanning where targets.isEmpty:
            "Scanning"
        case .ending(let done, let total):
            "Ending \(done) of \(total)"
        case .finished:
            "Session ended"
        default:
            eligible.isEmpty ? emptyHeadline : inventory
        }
    }

    private var emptyHeadline: String {
        switch lifecycle {
        case .before: "No leftovers from earlier sessions"
        case .during: "No runaways or duplicates"
        case .after: "Nothing left running"
        }
    }

    /// Leads with age, not count.
    ///
    /// "14 items" is a receipt. "oldest 6h 12m" is the six hours you spent not
    /// knowing — which is the thing that makes someone press the button.
    private var inventory: String {
        let items = Format.items(eligible.count)
        guard let oldest = eligible.compactMap(\.startedAt).min() else { return items }
        return "\(items) · oldest \(Format.duration(since: oldest))"
    }

    // MARK: - Actions

    func refresh() async {
        guard !isBusy else { return }
        // Only announce a scan on a cold start. A refresh triggered right after
        // a run must not overwrite the result the user is still reading.
        if targets.isEmpty, phase == .idle { phase = .scanning }

        // The scanner is an actor, so this already runs off the main thread.
        apply(await scanner.scan())
    }

    private func apply(_ result: SessionScan) {
        let known = Set(targets.map(\.id))
        let previous = selection

        scan = result
        targets = result.targets
        hasCPURates = result.hasCPURates

        // Preserve intent across refreshes: keep what the user chose, and let
        // the policy decide only for rows they have never seen.
        selection = Set(
            result.targets
                .filter { target in
                    known.contains(target.id)
                        ? previous.contains(target.id)
                        : policy.isPreselected(target, phase: lifecycle)
                }
                .map(\.id)
        )

        lastScan = result.scannedAt
        if case .finished = phase {} else { phase = .idle }
    }

    /// Changing phase re-derives selection from scratch. Carrying a teardown
    /// selection into triage would defeat the point of having phases.
    func setLifecycle(_ next: SessionPolicy.Phase) {
        guard next != lifecycle else { return }
        lifecycle = next
        selection = policy.selection(from: targets, phase: next)
        dismissResult()
    }

    func toggle(_ id: Target.ID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Section header acts on its whole group — the "end everything Cursor
    /// left" case, without a per-provider menu.
    func toggleProvider(_ provider: Provider) {
        let ids = eligible.filter { $0.provider == provider }.map(\.id)
        if ids.allSatisfy(selection.contains) {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
    }

    func isFullySelected(_ provider: Provider) -> Bool {
        let ids = eligible.filter { $0.provider == provider }.map(\.id)
        return !ids.isEmpty && ids.allSatisfy(selection.contains)
    }

    func selectAll() { selection = Set(eligible.map(\.id)) }
    func selectNone() { selection.removeAll() }

    func endSession() async {
        let chosen = selectedTargets
        guard !chosen.isEmpty, let scan, !isBusy else { return }

        resultDismissal?.cancel()
        endingOrder = chosen.map(\.id)
        endedCount = 0
        phase = .ending(done: 0, total: chosen.count)

        let reaper = Reaper(
            guardrail: SafetyGuard(ownLineage: scan.lineage),
            table: scan.table
        )

        let outcomes = await reaper.end(chosen) { [weak self] done, total in
            Task { @MainActor in
                guard let self, case .ending = self.phase else { return }
                // `progress` fires *before* the target at this index is
                // touched, so `done` is both the finished count and the index
                // now in hand. That is exactly what `endState` reads.
                self.endedCount = done
                self.phase = .ending(done: done, total: total)
            }
        }

        let succeeded = outcomes.filter(\.succeeded)
        phase = .finished(
            ended: succeeded.count,
            reclaimed: succeeded.reduce(0) { $0 + $1.reclaimedBytes },
            failures: outcomes.filter { !$0.succeeded }
        )

        // Ports and containers genuinely changed just now, so the cached
        // shell probes must not be trusted for the confirming scan.
        await scanner.invalidateShellCaches()
        await refresh()
        // Cleared only after the confirming scan has replaced the list, so the
        // resolved rows never blink back to their normal appearance in the
        // frame between finishing and refreshing.
        endingOrder = []
        endedCount = 0
        scheduleResultDismissal()
    }

    /// The result line is information, not a dialog. It leaves on its own.
    private func scheduleResultDismissal() {
        resultDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, case .finished = self.phase else { return }
                self.phase = .idle
            }
        }
    }

    func dismissResult() {
        resultDismissal?.cancel()
        if case .finished = phase { phase = .idle }
    }
}
