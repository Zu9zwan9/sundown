import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Ends things, politely first.
///
/// SIGTERM, then wait, then SIGKILL only for what refused to leave. Children
/// go before parents so a supervisor can't respawn what we just ended.
public actor Reaper {

    private let guardrail: SafetyGuard
    private let table: [pid_t: ProcessSnapshot]
    private let containers = ContainerScanner()

    public init(guardrail: SafetyGuard, table: [pid_t: ProcessSnapshot]) {
        self.guardrail = guardrail
        self.table = table
    }

    /// - Parameter grace: how long a process gets to exit on its own.
    ///   Three seconds is enough for a node server to close its handles and
    ///   short enough that the UI doesn't feel stuck.
    public func end(
        _ targets: [Target],
        grace: Duration = .seconds(3),
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Outcome] {

        var outcomes: [Outcome] = []
        let total = targets.count

        for (index, target) in targets.enumerated() {
            progress?(index, total)

            switch target.handle {
            case .process(let pid):
                outcomes.append(await endProcess(target, pid: pid, grace: grace))
            case .container(let id):
                outcomes.append(endContainer(target, id: id))
            }
        }

        progress?(total, total)
        return outcomes
    }

    // MARK: - Processes

    private func endProcess(_ target: Target, pid: pid_t, grace: Duration) async -> Outcome {
        // Decide everything before signalling anything.
        //
        // If the primary target is refused, its children must not be touched
        // either — a subtree with its leaves killed and its root alive is worse
        // than one left alone, and it is the state you get from checking each
        // process as you go.
        if let root = table[pid], case .refused(let reason) = guardrail.verdict(for: root) {
            return Outcome(
                id: target.id, title: target.title,
                result: .refused(reason), reclaimedBytes: 0
            )
        }

        // Leaves inward, so a parent never sees a half-dead child and restarts
        // it. `descendants` is breadth-first from the root, so reversing puts
        // the deepest processes first.
        let ordered = Array(target.descendants.reversed()) + [pid]
        let permitted = ordered.filter { candidate in
            // Absent from the table means it exited between scan and act.
            guard let process = table[candidate] else { return false }
            return guardrail.verdict(for: process) == .allowed
        }

        var signalled: [pid_t] = []
        for candidate in permitted where kill(candidate, SIGTERM) == 0 {
            signalled.append(candidate)
        }

        guard !signalled.isEmpty else {
            return Outcome(
                id: target.id, title: target.title, result: .alreadyGone, reclaimedBytes: 0)
        }

        let survivors = await waitForExit(of: signalled, within: grace)
        guard !survivors.isEmpty else {
            return Outcome(
                id: target.id, title: target.title,
                result: .exitedOnRequest, reclaimedBytes: target.residentBytes
            )
        }

        for stubborn in survivors { _ = kill(stubborn, SIGKILL) }
        let remaining = await waitForExit(of: survivors, within: .milliseconds(800))

        if remaining.isEmpty {
            return Outcome(
                id: target.id, title: target.title,
                result: .forced, reclaimedBytes: target.residentBytes
            )
        }
        return Outcome(
            id: target.id, title: target.title,
            result: .failed("Survived SIGKILL"), reclaimedBytes: 0
        )
    }

    /// Polls rather than waits: we are not the parent of these processes, so
    /// `waitpid` isn't available to us. `kill(pid, 0)` is the portable probe.
    private func waitForExit(of pids: [pid_t], within limit: Duration) async -> [pid_t] {
        let deadline = ContinuousClock.now.advanced(by: limit)
        var alive = pids

        while !alive.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(60))
            alive = alive.filter { kill($0, 0) == 0 }
        }
        return alive
    }

    // MARK: - Containers

    private func endContainer(_ target: Target, id: String) -> Outcome {
        let stopped = containers.stop(id: id)
        return Outcome(
            id: target.id,
            title: target.title,
            result: stopped ? .exitedOnRequest : .failed("Docker refused to stop it"),
            reclaimedBytes: stopped ? target.residentBytes : 0
        )
    }
}
