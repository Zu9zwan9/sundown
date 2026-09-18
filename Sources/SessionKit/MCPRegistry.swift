import Foundation

/// What the user *declared*, read from their MCP client config files.
///
/// This is the half of the picture every other tool is missing. Config
/// managers read these files and never look at the process table. Port
/// killers read the process table and never look at these files. Joining them
/// turns a heuristic guess at a name into the literal key the user typed, and
/// catches servers whose command line contains no hint of MCP at all.
///
/// It is also the only place a *join key* exists. A transcript records a tool
/// call as `mcp__<serverId>__<toolName>`; a process is a command line. Neither
/// can be turned into the other. The config file is the row carrying both: the
/// key the client sanitises into `<serverId>`, and the argv it spawns.
public struct MCPRegistry: Sendable {

    /// How the client talks to the server, which decides what the process
    /// table can prove about it.
    ///
    /// A stdio server is a child process: seeing no process means it is not
    /// connected. A remote server is an HTTP connection owned by the client,
    /// with nothing of its own in the process table — so absence proves
    /// nothing, and saying "not running" about one would be a fabrication.
    public enum Transport: String, Sendable, Hashable {
        case stdio
        case remote
    }

    public struct Declaration: Sendable, Hashable {
        /// The key in `mcpServers` — "filesystem", "github", "postgres". For
        /// plugin-supplied servers, the fully-qualified name the client uses
        /// internally: `plugin:<plugin>:<server>`.
        public let name: String
        /// Which client declared it, for the evidence line.
        public let client: String
        /// The most distinctive token in the invocation, used for matching.
        /// Nil for servers with no local command to match against.
        public let fingerprint: String?

        /// What the server is pointed at — the directory, repo, or database in
        /// its arguments. `filesystem` is a name; `filesystem · ~/Documents`
        /// is a thing you recognise as yours.
        public let scope: String?

        public let transport: Transport

        /// Stable key for grouping duplicate instances of the same server.
        /// Scoped by client, so Cursor's `filesystem` and Claude Desktop's
        /// `filesystem` are two different things — because they are.
        public var identity: String { "\(client)/\(name)" }

        /// The id this server's tools carry in a transcript: the `<id>` in
        /// `mcp__<id>__<tool>`.
        ///
        /// Clients derive it from the config key by replacing every character
        /// that is not a letter, a digit or a hyphen with an underscore. That
        /// is a rule, not a resemblance, which is the entire point — the join
        /// is exact, so a miss is a real miss rather than a bad match.
        ///
        /// Checked against the machine this was built on: 81 distinct ids
        /// across 40 transcripts, and every config key that appeared at all
        /// mapped to one of them. `plugin:aws-startup-advisor:awspricing` to
        /// `plugin_aws-startup-advisor_awspricing`, `mcp-unframer-co` to
        /// itself, `claude.ai Notion` to `claude_ai_Notion`.
        public var transcriptID: String {
            String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        }

        public init(
            name: String,
            client: String,
            fingerprint: String?,
            scope: String? = nil,
            transport: Transport = .stdio
        ) {
            self.name = name
            self.client = client
            self.fingerprint = fingerprint
            self.scope = scope
            self.transport = transport
        }
    }

    public private(set) var declarations: [Declaration]

    public init(declarations: [Declaration]) {
        // Longest fingerprint first, so the most specific declaration wins
        // when two servers share a prefix. Unmatchable ones sort last; they
        // still exist as declarations, they just never claim a process.
        self.declarations = declarations.sorted {
            ($0.fingerprint?.count ?? -1) > ($1.fingerprint?.count ?? -1)
        }
    }

    /// Reads every config file we know about. Missing files are normal — most
    /// people run one or two clients — so absence is never an error.
    public static func fromDisk(
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> MCPRegistry {
        var found: [Declaration] = []
        for source in Source.all {
            let url = home.appending(path: source.path)
            found.append(contentsOf: parse(url, client: source.client))
        }
        found.append(contentsOf: desktopExtensions(home: home))
        found.append(contentsOf: codePlugins(home: home))
        return MCPRegistry(declarations: found)
    }

    /// The declaration this process is running, if any.
    public func declaration(matching process: ProcessSnapshot) -> Declaration? {
        guard !declarations.isEmpty else { return nil }
        let command = process.commandLine.lowercased()
        guard !command.isEmpty else { return nil }
        return declarations.first {
            guard let fingerprint = $0.fingerprint else { return false }
            return command.contains(fingerprint.lowercased())
        }
    }

    /// The declaration for a process, falling back to the nearest ancestor's
    /// when the process itself carries no trace of one.
    ///
    /// `npm exec @gitkraken/gk mcp` matches what the user declared; the binary
    /// it execs three levels down does not, and is the same server. Without
    /// this, every wrapper chain ends in a row named `node` with no config key
    /// to join on — which is most of what Sundown declines to judge.
    ///
    /// The walk stops at the first client it meets, so a server never inherits
    /// from a sibling that happens to sit higher up the same tree.
    public func declaration(
        matching process: ProcessSnapshot,
        in table: [pid_t: ProcessSnapshot]
    ) -> Declaration? {
        if let direct = declaration(matching: process) { return direct }

        var cursor = process.parentPID
        var seen: Set<pid_t> = [process.pid]
        while cursor > 1, let ancestor = table[cursor], seen.insert(cursor).inserted {
            if let inherited = declaration(matching: ancestor) { return inherited }
            if Provider.identifying(ancestor) != nil { return nil }
            cursor = ancestor.parentPID
        }
        return nil
    }

    public func declaration(identity: String) -> Declaration? {
        declarations.first { $0.identity == identity }
    }

    // MARK: - Sources

    struct Source {
        let path: String
        let client: String

        static let all: [Source] = [
            .init(
                path: "Library/Application Support/Claude/claude_desktop_config.json",
                client: "Claude Desktop"),
            .init(path: ".claude.json", client: "Claude Code"),
            .init(path: ".claude/settings.json", client: "Claude Code"),
            .init(path: ".mcp.json", client: "Claude Code"),
            .init(path: ".cursor/mcp.json", client: "Cursor"),
            .init(path: ".codeium/windsurf/mcp_config.json", client: "Windsurf"),
            .init(path: ".config/zed/settings.json", client: "Zed"),
        ]
    }

    /// Claude Desktop extensions, which are not in `claude_desktop_config.json`
    /// at all.
    ///
    /// Worth its own reader because it closed the largest hole on the machine
    /// this was built against: every server Claude Desktop was actually
    /// running came from here, and the config file the obvious implementation
    /// reads was empty. One directory per extension, each with a manifest
    /// naming the command the app will spawn.
    ///
    /// The fingerprint is the extension's own directory. The manifest writes
    /// `${__dirname}` and the app expands it, so that absolute path appears
    /// verbatim in the running process's argv — an exact match rather than a
    /// resemblance.
    static func desktopExtensions(home: URL) -> [Declaration] {
        let root = home.appending(path: "Library/Application Support/Claude/Claude Extensions")
        let directories =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []

        return directories.compactMap { directory -> Declaration? in
            let manifest = directory.appending(path: "manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                let manifestRoot = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let name = manifestRoot["name"] as? String
            else { return nil }

            let server = manifestRoot["server"] as? [String: Any] ?? [:]
            let config = server["mcp_config"] as? [String: Any] ?? [:]
            let arguments = config["args"] as? [String] ?? []

            return Declaration(
                name: name,
                client: "Claude Desktop",
                fingerprint: directory.path,
                scope: scope(arguments: arguments, excluding: directory.path),
                transport: (server["type"] as? String) == "remote" ? .remote : .stdio
            )
        }
    }

    /// Claude Code plugins, whose servers live in each plugin's own `.mcp.json`
    /// rather than in the user's.
    ///
    /// Named `plugin:<plugin>:<server>` because that is the name the client
    /// uses, and therefore the name that sanitises into the transcript id.
    /// Getting this wrong is not a display bug — it breaks the join.
    static func codePlugins(home: URL) -> [Declaration] {
        var found: [Declaration] = []
        for (plugin, directory) in codePluginDirectories(home: home) {
            // Two spellings in the wild: marketplace installs write
            // `.mcp.json`, account-synced plugins write `mcp.json`. Reading
            // one of them is how a running server ends up with no name.
            for manifest in [".mcp.json", "mcp.json"] {
                found += parse(
                    directory.appending(path: manifest),
                    client: "Claude Code", prefix: "plugin:\(plugin):")
            }
        }
        return found
    }

    /// Every plugin directory, keyed by the name the client uses.
    ///
    /// Plugins arrive two ways and only one was being read:
    /// `installed_plugins.json` lists marketplace installs, while
    /// `plugins/synced/` holds the ones synced from the account. A plugin
    /// missing here is a process Sundown can see running and cannot name, and
    /// an unnameable process is one it refuses to judge.
    private static func codePluginDirectories(home: URL) -> [(String, URL)] {
        var directories: [(String, URL)] = []
        var seen: Set<String> = []

        func add(_ plugin: String, _ directory: URL) {
            guard seen.insert(directory.standardizedFileURL.path).inserted else { return }
            directories.append((plugin, directory))
        }

        let index = home.appending(path: ".claude/plugins/installed_plugins.json")
        if let data = try? Data(contentsOf: index),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let plugins = root["plugins"] as? [String: Any]
        {
            for (key, value) in plugins {
                // "aws-startup-advisor@claude-plugins-official" — the
                // marketplace after the @ is not part of the name the client
                // uses, and therefore not part of the transcript id.
                let plugin = key.split(separator: "@").first.map(String.init) ?? key
                for case let install as [String: Any] in (value as? [Any] ?? []) {
                    guard let path = install["installPath"] as? String else { continue }
                    add(plugin, URL(fileURLWithPath: path))
                }
            }
        }

        // synced/<workspace>/<plugin>/, alongside `<plugin>.meta.json` files
        // that are not directories and carry an extension.
        for workspace in contents(of: home.appending(path: ".claude/plugins/synced")) {
            for plugin in contents(of: workspace) where plugin.pathExtension.isEmpty {
                add(plugin.lastPathComponent, plugin)
            }
        }
        return directories
    }

    private static func contents(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: - Parsing

    /// Tolerant by design. These files are hand-edited, vary between clients,
    /// and gain keys between releases. A shape we don't recognise yields no
    /// declarations rather than an error — the app still works, it just falls
    /// back to heuristics for that client.
    static func parse(_ url: URL, client: String, prefix: String = "") -> [Declaration] {
        guard let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var servers: [String: Any] = root["mcpServers"] as? [String: Any] ?? [:]

        // `~/.claude.json` nests a second copy per project. Merge them in;
        // a server declared anywhere is a server that might be running.
        if let projects = root["projects"] as? [String: Any] {
            for case let project as [String: Any] in projects.values {
                for (key, value) in project["mcpServers"] as? [String: Any] ?? [:] {
                    servers[key] = servers[key] ?? value
                }
            }
        }

        return servers.compactMap { name, raw -> Declaration? in
            guard let entry = raw as? [String: Any] else { return nil }
            let command = entry["command"] as? String ?? ""
            let arguments = entry["args"] as? [String] ?? []

            // A server reached over HTTP has no command and never will have a
            // process. It is still declared, and still costs context — it just
            // cannot be judged by the process table.
            let remote =
                entry["url"] != nil
                || ["http", "sse", "websocket"].contains(entry["type"] as? String ?? "")

            // Named `token`, not `fingerprint`, so the binding can't shadow the
            // function being called on the same line.
            let token = remote ? nil : fingerprint(command: command, arguments: arguments)
            // A local server we cannot fingerprint can never be matched to a
            // process, and calling it "declared but not running" would be a
            // guess dressed as a finding. Drop it rather than misreport it.
            guard remote || token != nil else { return nil }

            return Declaration(
                name: prefix + name,
                client: client,
                fingerprint: token,
                scope: scope(arguments: arguments, excluding: token ?? ""),
                transport: remote ? .remote : .stdio
            )
        }
    }

    /// What the server is pointed at, from its own arguments.
    ///
    /// Deliberately derived rather than looked up. A hand-written catalog of
    /// descriptions for known packages would go stale the week someone
    /// publishes a new server — and it would still not tell you *which*
    /// directory this particular `filesystem` is serving, which is the part
    /// that makes it recognisable as yours.
    static func scope(arguments: [String], excluding fingerprint: String) -> String? {
        let candidates = arguments.filter {
            $0 != fingerprint && !$0.hasPrefix("-") && $0.count > 1
        }
        // The last one: servers take their target last, after any flags.
        guard let raw = candidates.last else { return nil }

        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.contains("://") {
            return raw
        }
        guard raw.hasPrefix("/") || raw.hasPrefix("~") || raw.hasPrefix(".") else {
            // Not a path — a repo slug, a database name, a channel. Show it
            // whole if it's short enough to be a label rather than an essay.
            return raw.count <= 40 ? raw : nil
        }
        return abbreviate(path: raw)
    }

    /// `/Users/me/Documents/Work` → `~/Documents/Work`, and long paths
    /// collapse to their last two components.
    static func abbreviate(path: String) -> String {
        var result = path
        let home = NSHomeDirectory()
        if !home.isEmpty, result.hasPrefix(home) {
            result = "~" + result.dropFirst(home.count)
        }
        guard result.count > 34 else { return result }
        let parts = result.split(separator: "/")
        guard parts.count > 2 else { return result }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    /// The token most likely to appear verbatim in the running process's argv
    /// and least likely to appear in anything else.
    ///
    /// Package specs beat file paths: `@modelcontextprotocol/server-filesystem`
    /// identifies the server, while `/Users/me/Documents` is an argument *to*
    /// it and could be shared by half a dozen unrelated processes.
    static func fingerprint(command: String, arguments: [String]) -> String? {
        let meaningful = arguments.filter { $0.count > 3 && !$0.hasPrefix("-") }

        // Prefer a package-like token: not an absolute path, not a bare flag.
        if let package =
            meaningful
            .filter({ !$0.hasPrefix("/") && !$0.hasPrefix(".") })
            .max(by: { $0.count < $1.count })
        {
            return package
        }
        // Then the longest remaining argument.
        if let longest = meaningful.max(by: { $0.count < $1.count }) {
            return longest
        }
        // Finally the executable itself, for servers invoked with no arguments.
        let executable = command.split(separator: "/").last.map(String.init) ?? command
        return executable.count > 3 ? executable : nil
    }
}
