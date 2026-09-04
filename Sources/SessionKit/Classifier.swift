import Foundation

/// Decides what a process *is* from its command line.
///
/// The rules are data, not code, so they can be read, argued with, and
/// extended without touching logic. Each match carries the substring that
/// caused it — that string is shown to the user as evidence.
public struct Classifier: Sendable {

    public struct Match: Sendable {
        public let kind: Kind
        public let confidence: Confidence
        public let evidence: String
    }

    /// Interpreters that are only interesting because of what they're running.
    /// A bare `node` is noise; `node …/server-filesystem/index.js` is a target.
    static let runtimes: Set<String> = [
        "node", "node.js", "bun", "deno",
        "python", "python3", "python3.11", "python3.12", "python3.13",
        "uv", "uvx", "npx", "pnpx", "ruby", "perl", "java", "dotnet",
    ]

    /// Command-line fragments that identify an MCP server. Ordered most
    /// specific first so the evidence string is the most informative one.
    static let mcpMarkers: [String] = [
        "@modelcontextprotocol/",
        "modelcontextprotocol",
        "mcp-server-",
        "-mcp-server",
        "mcp_server",
        "_mcp",
        "mcp_",
        "mcp-remote",
        "mcp-proxy",
        "/mcp-",
        "-mcp/",
        "fastmcp",
    ]

    /// Agent CLIs, matched on argv[0]'s basename only — never on a substring,
    /// so a file named `aider-notes.md` in the command line can't trip it.
    static let agentExecutables: Set<String> = [
        "claude", "codex", "cursor-agent", "aider", "goose", "opencode",
        "gemini", "amp", "crush", "cline", "continue", "block-goose",
    ]

    public init() {}

    public func classify(_ process: ProcessSnapshot) -> Match? {
        let executable = process.executable
        let command = process.commandLine.lowercased()

        // An agent CLI, by name.
        if Self.agentExecutables.contains(executable) {
            return Match(kind: .agent, confidence: .certain, evidence: "Agent CLI: \(executable)")
        }

        // An MCP server, by marker. Strongest signal we have.
        for marker in Self.mcpMarkers where command.contains(marker) {
            return Match(kind: .mcpServer, confidence: .certain, evidence: "Matched “\(marker)”")
        }

        // `mcp` as a standalone argument token — catches `uvx some-tool mcp`
        // and `python -m foo.mcp` without matching the word inside a path.
        let tokens = Set(command.split(whereSeparator: { " /\\.".contains($0) }).map(String.init))
        if tokens.contains("mcp"), Self.runtimes.contains(executable) {
            return Match(kind: .mcpServer, confidence: .probable, evidence: "“mcp” in arguments")
        }

        return nil
    }

    // MARK: - Naming

    /// A short, human name for an MCP server.
    ///
    /// `node …/@modelcontextprotocol/server-filesystem/dist/index.js /Users/me`
    /// becomes `filesystem`, because that is what the user calls it.
    public static func displayName(for process: ProcessSnapshot) -> String {
        tidy(extractName(for: process), fallback: process.executable)
    }

    /// Strips the parts every server shares, so what's left is the part that
    /// distinguishes this one.
    ///
    /// `awslabs.aws-api-mcp-server` → `aws-api`, `server-pdf` → `pdf`,
    /// `pdf-server` → `pdf`. Without this, half the list reads as variations
    /// on the word "server" and the eye has nothing to catch on.
    static func tidy(_ raw: String, fallback: String) -> String {
        var name = raw

        // A dotted namespace in front of the real name: keep the last segment,
        // unless that segment is a file extension.
        if name.contains("."), let last = name.split(separator: ".").last,
            !fileExtensions.contains(String(last).lowercased()), last.count > 2
        {
            name = String(last)
        }
        // Drop a trailing extension: `index.js` should never be a title.
        if let dot = name.lastIndex(of: "."),
            fileExtensions.contains(String(name[name.index(after: dot)...]).lowercased())
        {
            name = String(name[name.startIndex..<dot])
        }

        for suffix in ["-mcp-server", "_mcp_server", "-mcp", "_mcp", "-server", "_server"]
        where name.hasSuffix(suffix) && name.count > suffix.count + 1 {
            name = String(name.dropLast(suffix.count))
            break
        }
        for prefix in ["mcp-server-", "mcp_server_", "mcp-", "mcp_", "server-", "server_"]
        where name.hasPrefix(prefix) && name.count > prefix.count + 1 {
            name = String(name.dropFirst(prefix.count))
            break
        }

        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return trimmed.isEmpty ? fallback : trimmed
    }

    static let fileExtensions: Set<String> = [
        "js", "mjs", "cjs", "ts", "py", "rb", "sh", "json", "jar", "exe",
    ]

    private static func extractName(for process: ProcessSnapshot) -> String {
        let command = process.commandLine

        // @modelcontextprotocol/server-NAME
        if let name = capture(in: command, after: "@modelcontextprotocol/server-") { return name }
        if let name = capture(in: command, after: "@modelcontextprotocol/") { return name }

        // mcp-server-NAME  /  NAME-mcp-server  /  NAME-mcp  /  mcp-NAME
        if let name = capture(in: command, after: "mcp-server-") { return name }
        for token in tokens(of: command) {
            if token.hasSuffix("-mcp-server") { return String(token.dropLast(11)) }
            if token.hasSuffix("-mcp") { return String(token.dropLast(4)) }
            if token.hasPrefix("mcp-"), token.count > 4 { return String(token.dropFirst(4)) }
        }

        // A scoped or plain package under node_modules.
        if let range = command.range(of: "node_modules/", options: .backwards) {
            let tail = command[range.upperBound...]
            var parts = tail.split(separator: "/").map(String.init)
            // `node_modules/.bin/mcp-server-pdf` names the shim directory, not
            // the package. Ten rows titled ".bin" is what that looks like.
            if parts.first == ".bin" { parts.removeFirst() }
            if let first = parts.first {
                if first.hasPrefix("@"), parts.count > 1 { return parts[1] }
                return first
            }
        }

        // A python module: `-m package.server`
        if let index = process.arguments.firstIndex(of: "-m"),
            index + 1 < process.arguments.count
        {
            let module = process.arguments[index + 1]
            return module.split(separator: ".").first.map(String.init) ?? module
        }

        return process.executable
    }

    private static func capture(in haystack: String, after prefix: String) -> String? {
        guard let range = haystack.range(of: prefix, options: .caseInsensitive) else { return nil }
        let tail = haystack[range.upperBound...]
        let name = tail.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        // Reject a bare version suffix or an empty capture.
        guard name.count > 1, name.first?.isLetter == true else { return nil }
        return String(name)
    }

    private static func tokens(of command: String) -> [String] {
        command
            .split(whereSeparator: { " /\\".contains($0) })
            .map { String($0).lowercased() }
    }
}
