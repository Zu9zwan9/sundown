import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The part of the app that says no.
///
/// Everything else in SessionKit proposes. This disposes. Every termination
/// path routes through `verdict(for:)` — there is no second way to send a
/// signal, and there should never be one.
public struct SafetyGuard: Sendable {

    /// Never candidates, whatever the rules think. Lowercased; matched against
    /// the kernel process name and against argv[0]'s last path component.
    ///
    /// Note what is *not* here: `claude`, `codex`, `aider`. Those CLIs are
    /// legitimate targets. The GUI apps that share their names are excluded
    /// structurally by `isApplicationBundle`, not by name — so we never have
    /// to choose between killing the wrong Claude and killing neither.
    public static let neverTouch: Set<String> = [
        // System
        "launchd", "kernel_task", "windowserver", "loginwindow", "systemuiserver",
        "dock", "finder", "spotlight", "mds", "mds_stores", "mdworker",
        "coreaudiod", "bluetoothd", "cfprefsd", "distnoted", "securityd",
        "notifyd", "opendirectoryd", "powerd", "syslogd", "usernoted", "sshd",

        // Shells and multiplexers. An agent usually runs *inside* one of these;
        // ending the shell would take the user's terminal down with it.
        "zsh", "bash", "fish", "sh", "dash", "tmux", "tmux: server", "screen",
        "login",

        // Editors that may have no readable argv.
        "xcode", "nvim", "vim", "emacs",

        // Container runtimes. We stop containers; we never stop the daemon.
        "dockerd", "com.docker.backend", "com.docker.vpnkit", "containerd",
        "orbstack", "colima", "podman", "vfkit", "qemu-system-aarch64",

        // Us.
        "sundown",
    ]

    /// Below this, you are looking at the operating system.
    public static let lowestKillablePID: pid_t = 100

    public enum Verdict: Sendable, Equatable {
        case allowed
        case refused(String)
    }

    private let currentUser: uid_t
    private let ownLineage: Set<pid_t>

    /// - Parameter ownLineage: our own pid and every ancestor, so Sundown can
    ///   never end the process doing the ending.
    public init(currentUser: uid_t = getuid(), ownLineage: Set<pid_t>) {
        self.currentUser = currentUser
        self.ownLineage = ownLineage
    }

    public func verdict(for process: ProcessSnapshot) -> Verdict {
        if process.pid < Self.lowestKillablePID {
            return .refused("System process")
        }
        if ownLineage.contains(process.pid) {
            return .refused("Sundown itself")
        }
        if process.userID != currentUser {
            return .refused("Owned by another user")
        }
        if Self.isApplicationBundle(process) {
            return .refused("Part of an application")
        }
        if Self.neverTouch.contains(process.name.lowercased()) {
            return .refused("Protected: \(process.name)")
        }
        if Self.neverTouch.contains(process.executable) {
            return .refused("Protected: \(process.executable)")
        }
        return .allowed
    }

    /// A GUI application, its helpers, or an XPC service.
    ///
    /// This is the rule that keeps us from quitting Claude Desktop, Cursor,
    /// VS Code, or a terminal while cleaning up the CLIs they spawned. It is
    /// structural rather than a name list, so it holds for apps we've never
    /// heard of.
    public static func isApplicationBundle(_ process: ProcessSnapshot) -> Bool {
        guard let path = process.arguments.first, !path.isEmpty else {
            // No argv to inspect. Be conservative: anything with a capital
            // letter or a space in its kernel name is almost certainly a
            // bundled app rather than a unix tool.
            let name = process.name
            return name.contains(" ") || name.contains(where: \.isUppercase)
        }
        return path.contains(".app/Contents/")
            || path.contains(".appex/")
            || path.contains(".xpc/")
            || path.hasPrefix("/System/")
            || path.hasPrefix("/usr/libexec/")
    }

    /// Our pid plus every ancestor, walked through the given table.
    public static func lineage(
        of pid: pid_t = getpid(),
        in table: [pid_t: ProcessSnapshot]
    ) -> Set<pid_t> {
        var seen: Set<pid_t> = [pid]
        var cursor = pid
        // Bounded: real ancestry is a handful deep, and the bound also
        // protects against a cycle in a corrupt table.
        for _ in 0..<64 {
            guard let parent = table[cursor]?.parentPID, parent > 0,
                !seen.contains(parent)
            else { break }
            seen.insert(parent)
            cursor = parent
        }
        return seen
    }
}
