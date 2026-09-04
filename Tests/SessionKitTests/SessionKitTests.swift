import XCTest

@testable import SessionKit

/// These cover the two functions that can do damage if they're wrong:
/// what we decide to call a target, and what we refuse to touch.
final class SessionKitTests: XCTestCase {

    // MARK: - Fixtures

    private func process(
        pid: pid_t = 4821,
        ppid: pid_t = 900,
        uid: uid_t = 501,
        name: String = "node",
        _ argv: String...
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid, parentPID: ppid, userID: uid, name: name,
            arguments: argv, startedAt: Date(timeIntervalSince1970: 0),
            residentBytes: 128 << 20
        )
    }

    // MARK: - Naming

    func testNamesOfficialMCPServers() {
        let p = process(
            "/usr/local/bin/node",
            "/Users/me/.npm/_npx/a1/node_modules/@modelcontextprotocol/server-filesystem/dist/index.js",
            "/Users/me/Documents"
        )
        XCTAssertEqual(Classifier.displayName(for: p), "filesystem")
    }

    func testNamesHyphenatedServerPackages() {
        let p = process("/usr/local/bin/node", "/opt/tools/mcp-server-github/index.js")
        XCTAssertEqual(Classifier.displayName(for: p), "github")
    }

    func testNamesSuffixStyleServerPackages() {
        let p = process(
            "/usr/local/bin/node",
            "/Users/me/proj/node_modules/@upstash/context7-mcp/dist/index.js"
        )
        XCTAssertEqual(Classifier.displayName(for: p), "context7")
    }

    func testNamesPythonModules() {
        let p = process(name: "python3", "/usr/bin/python3", "-m", "weather_mcp.server")
        // `weather`, not `weather_mcp`: the `_mcp` is true of every row.
        XCTAssertEqual(Classifier.displayName(for: p), "weather")
    }

    // MARK: - Name cleanup

    /// Real output from a live machine: ten rows reading `.bin`, and one
    /// reading `ant.dir.gh.awslabs.aws-api`. Neither is a name.
    func testDoesNotNameAPackageAfterItsShimDirectory() {
        let p = process(
            "/usr/local/bin/node",
            "/Users/me/proj/node_modules/.bin/mcp-server-pdf"
        )
        XCTAssertEqual(Classifier.displayName(for: p), "pdf")
    }

    func testStripsDottedNamespacesAndSharedSuffixes() {
        XCTAssertEqual(Classifier.tidy("awslabs.aws-api-mcp-server", fallback: "x"), "aws-api")
        XCTAssertEqual(
            Classifier.tidy("ant.dir.gh.awslabs.aws-api-mcp-server", fallback: "x"), "aws-api")
        XCTAssertEqual(Classifier.tidy("pdf-server", fallback: "x"), "pdf")
        XCTAssertEqual(Classifier.tidy("server-pdf", fallback: "x"), "pdf")
        XCTAssertEqual(Classifier.tidy("mcp-server-github", fallback: "x"), "github")
    }

    func testLeavesAlreadyCleanNamesAlone() {
        XCTAssertEqual(Classifier.tidy("filesystem", fallback: "x"), "filesystem")
        XCTAssertEqual(Classifier.tidy("context7", fallback: "x"), "context7")
    }

    /// A file extension is not a namespace. `index.js` must not become `js`.
    func testNeverReducesAFilenameToItsExtension() {
        XCTAssertEqual(Classifier.tidy("index.js", fallback: "node"), "index")
        XCTAssertEqual(Classifier.tidy("main.py", fallback: "python3"), "main")
    }

    func testFallsBackRatherThanReturningNothing() {
        // Stripping every component would leave an empty title, which is
        // worse than the imperfect name we started with.
        XCTAssertEqual(Classifier.tidy("server", fallback: "node"), "server")
        XCTAssertEqual(Classifier.tidy("-", fallback: "node"), "node")
        XCTAssertEqual(Classifier.tidy("", fallback: "node"), "node")
    }

    func testFallsBackToExecutableName() {
        let p = process(name: "ripgrep", "/opt/homebrew/bin/rg", "--files")
        XCTAssertEqual(Classifier.displayName(for: p), "rg")
    }

    // MARK: - Classification

    func testClassifiesOfficialServerAsCertain() {
        let p = process("/usr/local/bin/node", "/x/@modelcontextprotocol/server-git/index.js")
        let match = Classifier().classify(p)
        XCTAssertEqual(match?.kind, .mcpServer)
        XCTAssertEqual(match?.confidence, .certain)
    }

    func testClassifiesAgentCLIByExecutableOnly() {
        let agent = process(name: "claude", "/Users/me/.local/bin/claude")
        XCTAssertEqual(Classifier().classify(agent)?.kind, .agent)

        // The word appearing in a path must not make something an agent.
        let bystander = process(name: "cat", "/bin/cat", "/Users/me/notes/aider-todo.md")
        XCTAssertNil(Classifier().classify(bystander))
    }

    func testLeavesOrdinaryProcessesAlone() {
        XCTAssertNil(Classifier().classify(process("/usr/local/bin/node", "server.js")))
        XCTAssertNil(Classifier().classify(process(name: "rustc", "/usr/bin/rustc", "main.rs")))
    }

    func testLooseMCPMatchIsOnlyProbableAndOnlyForRuntimes() {
        let runtime = process(name: "uvx", "/opt/homebrew/bin/uvx", "weather", "mcp")
        XCTAssertEqual(Classifier().classify(runtime)?.confidence, .probable)

        // Same token, but not an interpreter — not our business.
        let other = process(name: "grep", "/usr/bin/grep", "mcp", "log.txt")
        XCTAssertNil(Classifier().classify(other))
    }

    // MARK: - Safety

    private var guardrail: SafetyGuard {
        SafetyGuard(currentUser: 501, ownLineage: [4200, 4201])
    }

    func testRefusesLowPIDs() {
        let verdict = guardrail.verdict(for: process(pid: 1, name: "launchd", "/sbin/launchd"))
        XCTAssertEqual(verdict, .refused("System process"))
    }

    func testRefusesItself() {
        // Above the PID floor on purpose: this must be refused because it is
        // us, not because it happens to be a low-numbered process.
        XCTAssertEqual(
            guardrail.verdict(for: process(pid: 4200, name: "sundown", "/opt/bin/sundown")),
            .refused("Sundown itself")
        )
    }

    func testRefusesOtherUsers() {
        XCTAssertEqual(
            guardrail.verdict(for: process(uid: 0, name: "node", "/usr/local/bin/node", "x.js")),
            .refused("Owned by another user")
        )
    }

    func testRefusesApplicationBundlesIncludingTheClientItself() {
        // Claude Desktop. Its leftovers are our job; the app is not.
        let desktop = process(
            name: "Claude",
            "/Applications/Claude.app/Contents/MacOS/Claude"
        )
        XCTAssertEqual(guardrail.verdict(for: desktop), .refused("Part of an application"))

        // …while the CLI of the same name stays a legitimate target.
        let cli = process(name: "claude", "/Users/me/.local/bin/claude")
        XCTAssertEqual(guardrail.verdict(for: cli), .allowed)
    }

    func testRefusesShellsAndSystemPaths() {
        XCTAssertEqual(
            guardrail.verdict(for: process(name: "zsh", "/bin/zsh", "-l")),
            .refused("Protected: zsh")
        )
        XCTAssertEqual(
            guardrail.verdict(for: process(name: "trustd", "/System/Library/x/trustd")),
            .refused("Part of an application")
        )
    }

    func testAllowsAnOrdinaryUserProcess() {
        XCTAssertEqual(
            guardrail.verdict(for: process("/usr/local/bin/node", "/x/server-filesystem/index.js")),
            .allowed
        )
    }

    func testLineageWalksToTheRootAndSurvivesCycles() {
        let table: [pid_t: ProcessSnapshot] = [
            10: process(pid: 10, ppid: 5),
            5: process(pid: 5, ppid: 1),
            1: process(pid: 1, ppid: 0),
        ]
        XCTAssertEqual(SafetyGuard.lineage(of: 10, in: table), [10, 5, 1])

        let cyclic: [pid_t: ProcessSnapshot] = [
            10: process(pid: 10, ppid: 11),
            11: process(pid: 11, ppid: 10),
        ]
        XCTAssertEqual(SafetyGuard.lineage(of: 10, in: cyclic), [10, 11])
    }

    // MARK: - Ports

    func testParsesLsofAddresses() {
        XCTAssertEqual(PortScanner.port(from: "*:5173"), 5173)
        XCTAssertEqual(PortScanner.port(from: "127.0.0.1:8080"), 8080)
        XCTAssertEqual(PortScanner.port(from: "[::1]:3000"), 3000)
        XCTAssertNil(PortScanner.port(from: "localhost"))
    }

    // MARK: - Config registry

    /// The join that separates Sundown from every port killer and every config
    /// manager: a running process matched to the name the user typed.
    func testMatchesRunningProcessToDeclaredServer() {
        let registry = MCPRegistry(declarations: [
            .init(
                name: "filesystem", client: "Claude Desktop",
                fingerprint: "@modelcontextprotocol/server-filesystem", scope: nil),
            .init(
                name: "weather", client: "Claude Code", fingerprint: "weather-service", scope: nil),
        ])

        let running = process(
            "/usr/local/bin/node",
            "/Users/me/.npm/_npx/a1/node_modules/@modelcontextprotocol/server-filesystem/dist/index.js"
        )
        XCTAssertEqual(registry.declaration(matching: running)?.name, "filesystem")
        XCTAssertEqual(registry.declaration(matching: running)?.client, "Claude Desktop")

        let unrelated = process("/usr/local/bin/node", "/x/some-other-thing/index.js")
        XCTAssertNil(registry.declaration(matching: unrelated))
    }

    func testMostSpecificDeclarationWins() {
        let registry = MCPRegistry(declarations: [
            .init(name: "generic", client: "Cursor", fingerprint: "server", scope: nil),
            .init(name: "postgres", client: "Cursor", fingerprint: "server-postgres", scope: nil),
        ])
        let running = process("/usr/local/bin/node", "/x/server-postgres/index.js")
        XCTAssertEqual(registry.declaration(matching: running)?.name, "postgres")
    }

    // MARK: - Scope

    /// What a server is pointed at is what makes it recognisable. Two
    /// `filesystem` servers are indistinguishable by name and obvious by scope.
    func testDerivesScopeFromArguments() {
        XCTAssertEqual(
            MCPRegistry.scope(
                arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp/work"],
                excluding: "@modelcontextprotocol/server-filesystem"
            ),
            "/tmp/work"
        )
        XCTAssertEqual(
            MCPRegistry.scope(
                arguments: ["mcp-server-git", "--repository", "myorg/myrepo"],
                excluding: "mcp-server-git"
            ),
            "myorg/myrepo"
        )
        XCTAssertEqual(
            MCPRegistry.scope(
                arguments: ["server-postgres", "postgresql://localhost/app"],
                excluding: "server-postgres"
            ),
            "postgresql://localhost/app"
        )
        // Nothing but the package itself — no scope to show, and we say so
        // rather than inventing one.
        XCTAssertNil(
            MCPRegistry.scope(arguments: ["-y", "server-github"], excluding: "server-github")
        )
    }

    func testAbbreviatesLongPaths() {
        XCTAssertEqual(
            MCPRegistry.abbreviate(path: NSHomeDirectory() + "/Documents"),
            "~/Documents"
        )
        XCTAssertEqual(
            MCPRegistry.abbreviate(path: "/opt/very/deeply/nested/directory/structure/here/final"),
            "…/here/final"
        )
        XCTAssertEqual(MCPRegistry.abbreviate(path: "/tmp/work"), "/tmp/work")
    }

    func testFingerprintPrefersPackageSpecOverPath() {
        XCTAssertEqual(
            MCPRegistry.fingerprint(
                command: "npx",
                arguments: [
                    "-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Documents/a/b",
                ]
            ),
            "@modelcontextprotocol/server-filesystem"
        )
        XCTAssertEqual(
            MCPRegistry.fingerprint(
                command: "uvx", arguments: ["mcp-server-git", "--repository", "/r"]),
            "mcp-server-git"
        )
        // No usable arguments — fall back to the executable itself.
        XCTAssertEqual(
            MCPRegistry.fingerprint(command: "/usr/local/bin/weather-mcp", arguments: []),
            "weather-mcp"
        )
    }

    func testParsesClaudeDesktopShapeAndProjectNesting() throws {
        let json = """
            {
              "mcpServers": {
                "filesystem": { "command": "npx",
                                "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"] }
              },
              "projects": {
                "/Users/me/work": {
                  "mcpServers": { "github": { "command": "npx", "args": ["-y", "server-github"] } }
                }
              }
            }
            """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "sundown-test-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let declarations = MCPRegistry.parse(url, client: "Claude Code")
        XCTAssertEqual(Set(declarations.map(\.name)), ["filesystem", "github"])
    }

    func testMalformedConfigYieldsNothingRatherThanThrowing() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "sundown-bad-\(UUID().uuidString).json")
        try Data("{ not json at all".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(MCPRegistry.parse(url, client: "Cursor").isEmpty)
        // A file that doesn't exist is normal, not an error.
        XCTAssertTrue(
            MCPRegistry.parse(URL(fileURLWithPath: "/nope/nowhere.json"), client: "Cursor").isEmpty
        )
    }

    // MARK: - Formatting-adjacent invariants

    func testKindOrderingPutsCertaintyFirst() {
        XCTAssertEqual(
            [Kind.listener, .agent, .container, .mcpServer].sorted(),
            [.mcpServer, .agent, .container, .listener]
        )
    }
}
