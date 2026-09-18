import Foundation

/// Which tool a process belongs to.
///
/// This is the difference between "you have 14 stray processes" and "Claude
/// Code left 6 behind and Cursor left 4." The second is actionable; the first
/// is just a number. It also makes per-tool cleanup possible without going
/// near any agent's own UI.
public struct Provider: Hashable, Sendable, Identifiable, Comparable {

    public let id: String
    public let name: String
    /// Display order. Attributed providers before the catch-all.
    let rank: Int

    init(id: String, name: String, rank: Int) {
        self.id = id
        self.name = name
        self.rank = rank
    }

    public static let claudeDesktop = Provider(
        id: "claude-desktop", name: "Claude Desktop", rank: 0)
    public static let claudeCode = Provider(id: "claude-code", name: "Claude Code", rank: 1)
    public static let codex = Provider(id: "codex", name: "Codex", rank: 2)
    public static let cursor = Provider(id: "cursor", name: "Cursor", rank: 3)
    public static let copilot = Provider(id: "copilot", name: "Copilot CLI", rank: 4)
    public static let windsurf = Provider(id: "windsurf", name: "Windsurf", rank: 5)
    public static let zed = Provider(id: "zed", name: "Zed", rank: 6)
    public static let antigravity = Provider(id: "antigravity", name: "Antigravity", rank: 7)
    public static let aider = Provider(id: "aider", name: "Aider", rank: 8)
    public static let goose = Provider(id: "goose", name: "Goose", rank: 9)
    public static let vsCode = Provider(id: "vscode", name: "VS Code", rank: 10)

    /// We found the process but can't prove whose it is. Named honestly:
    /// "Other" would imply we know it isn't one of the above.
    public static let unattributed = Provider(id: "unattributed", name: "Unattributed", rank: 99)

    public static let known: [Provider] = [
        .claudeDesktop, .claudeCode, .codex, .cursor, .copilot,
        .windsurf, .zed, .antigravity, .aider, .goose, .vsCode,
    ]

    public static func < (a: Provider, b: Provider) -> Bool {
        a.rank == b.rank ? a.id < b.id : a.rank < b.rank
    }

    /// The client a process *is*, if any.
    ///
    /// Ancestry walks stop here: a client is where one server's subtree ends
    /// and the next one's begins.
    public static func identifying(_ process: ProcessSnapshot) -> Provider? {
        if let path = process.arguments.first, let bundle = fromBundlePath(path) {
            return bundle
        }
        return fromExecutable(process.executable)
    }

    /// Resolve from a CLI's executable name — argv[0]'s last component.
    public static func fromExecutable(_ executable: String) -> Provider? {
        switch executable.lowercased() {
        case "claude": .claudeCode
        case "codex": .codex
        case "cursor-agent": .cursor
        case "copilot", "gh-copilot": .copilot
        case "windsurf": .windsurf
        case "aider": .aider
        case "goose", "block-goose": .goose
        case "antigravity": .antigravity
        default: nil
        }
    }

    /// Resolve from an application bundle path.
    ///
    /// Matched on the `.app` directory name specifically, not on a substring
    /// of the whole path — otherwise a project folder called `cursor-notes`
    /// would misattribute everything beneath it.
    public static func fromBundlePath(_ path: String) -> Provider? {
        guard let bundle = appBundleName(in: path)?.lowercased() else { return nil }
        switch bundle {
        case "claude": return .claudeDesktop
        case "cursor": return .cursor
        case "windsurf": return .windsurf
        case "zed": return .zed
        case "antigravity": return .antigravity
        case "visual studio code", "code": return .vsCode
        default: return nil
        }
    }

    /// The name of the outermost `.app` in a path, if any.
    /// `/Applications/Claude.app/Contents/MacOS/Claude` → `Claude`
    static func appBundleName(in path: String) -> String? {
        for component in path.split(separator: "/") where component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return nil
    }

    /// Resolve from the name of the config file that declared a server.
    /// `MCPRegistry` already records this, so it's a lookup, not a guess.
    public static func named(_ clientName: String) -> Provider {
        known.first { $0.name == clientName } ?? .unattributed
    }
}
