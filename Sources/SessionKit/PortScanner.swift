import Foundation

/// Finds who is holding a listening TCP port.
///
/// Used two ways: to annotate a target we already found ("filesystem · :6277"),
/// and to surface dev servers and watchers that no rule caught but that are
/// squatting on a port the user will want back.
struct PortScanner: Sendable {

    struct Listener: Sendable, Hashable {
        let pid: pid_t
        let command: String
        let port: UInt16
    }

    /// Ports below this are system services; above 1024 is where dev servers live.
    static let firstUserPort: UInt16 = 1024

    func scan() -> [Listener] {
        guard let lsof = Shell.locate(["/usr/sbin/lsof", "/usr/bin/lsof"]) else { return [] }

        // -F pcn is lsof's machine-readable mode: one field per line, prefixed
        // by its type. Far more robust than parsing the human table.
        guard
            let result = Shell.run(
                lsof, ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]
            ), result.status == 0 || !result.output.isEmpty
        else { return [] }

        var listeners: Set<Listener> = []
        var pid: pid_t?
        var command = ""

        for line in result.output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())

            switch tag {
            case "p":
                pid = pid_t(value)
                command = ""
            case "c":
                command = value
            case "n":
                guard let pid, let port = Self.port(from: value), port >= Self.firstUserPort
                else { continue }
                listeners.insert(Listener(pid: pid, command: command, port: port))
            default:
                continue
            }
        }

        return listeners.sorted { $0.port < $1.port }
    }

    /// `*:5173`, `127.0.0.1:5173`, `[::1]:5173` → `5173`
    static func port(from name: String) -> UInt16? {
        guard let colon = name.lastIndex(of: ":") else { return nil }
        return UInt16(name[name.index(after: colon)...])
    }
}
