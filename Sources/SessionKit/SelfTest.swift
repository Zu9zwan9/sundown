import Foundation

/// The join, checked end to end, on the machine it is running on.
///
/// `sundown --self-test` exists because the join is the product and it depends
/// on three things Sundown does not control: where a client keeps its config,
/// how it sanitises a config key into a tool-name prefix, and where it writes
/// transcripts. Any of those can change in a client release, and when one does
/// the failure is silent — the tool goes back to abstaining and looks merely
/// cautious rather than broken.
///
/// Checks record and continue rather than trapping, so one broken link doesn't
/// hide the other nine. Note they are `expect`, not `assert`: `assert` compiles
/// out of a release build, which is the only build anybody runs.
public enum SelfTest {

    public static func run() -> (lines: [String], passed: Bool) {
        var failures: [String] = []
        var lines: [String] = []

        func expect(_ condition: Bool, _ description: String) {
            if !condition { failures.append(description) }
        }

        // MARK: The naming rule
        //
        // If this breaks, every server goes back to "no evidence either way".
        let cases = [
            ("elevenlabs", "elevenlabs"),
            ("mcp-unframer-co", "mcp-unframer-co"),
            ("claude.ai Notion", "claude_ai_Notion"),
            ("plugin:aws-startup-advisor:awspricing", "plugin_aws-startup-advisor_awspricing"),
            ("plugin:RevenueCat:RevenueCat", "plugin_RevenueCat_RevenueCat"),
        ]
        for (name, expected) in cases {
            let declaration = MCPRegistry.Declaration(
                name: name, client: "Claude Code", fingerprint: "x")
            expect(
                declaration.transcriptID == expected,
                "transcript id for '\(name)' was '\(declaration.transcriptID)', expected '\(expected)'"
            )
        }

        // MARK: Duplicates are instances, not servers
        let table: [pid_t: ProcessSnapshot] = [:]
        let duplicated = (1...4).map { pid in
            target(pid: pid_t(pid), title: "pdf", declarationKey: "Claude Code/pdf")
        }
        let registry = MCPRegistry(declarations: [
            .init(name: "pdf", client: "Claude Code", fingerprint: "server-pdf")
        ])
        let deduplicated = ServerRecord.build(
            targets: duplicated, table: table, registry: registry, metrics: nil)
        expect(
            deduplicated.filter { $0.state == .running }.count == 1,
            "four processes of one declaration produced "
                + "\(deduplicated.filter { $0.state == .running }.count) records, expected 1")
        expect(
            deduplicated.first?.pids.count == 4,
            "the four pids were not collected onto one record")
        expect(
            deduplicated.first?.configKey == "Claude Code/pdf",
            "a declared server came back without its config key")

        // MARK: An unidentified process abstains rather than scoring zero
        let stranger = ServerRecord.build(
            targets: [target(pid: 99, title: "node", declarationKey: nil)],
            table: table, registry: registry, metrics: nil)
        expect(stranger.first?.configKey == nil, "an unmatched process claimed a config key")
        expect(
            stranger.first?.calls == nil,
            "an unmatched process reported a call count; nil and 0 must stay distinct")

        // MARK: Old snapshots migrate, and say so
        let v1 = """
            {"fixedPrefixTokens":39358,"servers":["pdf","pdf","pdf","aws-api","aws-api"],
             "takenAt":"2026-08-14T23:13:01Z","turnsObserved":795}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let migrated = try? decoder.decode(ContextSnapshot.self, from: Data(v1.utf8)) {
            expect(migrated.migrated, "a v1 snapshot decoded without being flagged as migrated")
            expect(
                migrated.servers.count == 2,
                "v1 migration kept \(migrated.servers.count) servers, expected 2 distinct")
            expect(
                migrated.fixedPrefixTokens == 39358,
                "v1 migration lost the token figure, which was always correct")
            expect(
                migrated.servers.allSatisfy { $0.configKey == nil },
                "v1 migration invented config keys it could not have known")
        } else {
            failures.append("a v1 snapshot failed to decode at all")
        }

        // MARK: v2 round-trips
        let record = ServerRecord(
            id: "prisma", configKey: "Claude Code/prisma", argv: "npx -y prisma mcp",
            pids: [62448, 62449], tokens: 4231, calls: 12)
        let snapshot = ContextSnapshot(
            takenAt: Date(), fixedPrefixTokens: 39358, servers: [record], turnsObserved: 795)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot),
            let restored = try? decoder.decode(ContextSnapshot.self, from: data)
        {
            expect(!restored.migrated, "a freshly written snapshot decoded as migrated")
            expect(restored.servers == [record], "a v2 snapshot did not survive a round trip")
        } else {
            failures.append("a v2 snapshot failed to round-trip")
        }

        // MARK: Removed, stopped and added are three different things
        let gone = ServerRecord(id: "gone", configKey: "Claude Code/gone", argv: "", pids: [1])
        let stopped = ServerRecord(
            id: "prisma", configKey: "Claude Code/prisma", argv: "", pids: [2])
        let before = ContextSnapshot(
            takenAt: Date(timeIntervalSinceNow: -3600), fixedPrefixTokens: 40000,
            servers: [gone, stopped], turnsObserved: 100)
        let after = [
            ServerRecord(
                id: "prisma", configKey: "Claude Code/prisma", argv: "", pids: [],
                state: .declaredNotRunning)
        ]
        let comparison = ContextComparison(
            before: before, afterPrefixTokens: 35000, afterServers: after, turnsSince: 50)
        expect(
            comparison.removed.map(\.diffKey) == ["Claude Code/gone"],
            "a server absent from the config was not reported as removed")
        expect(
            comparison.stopped.map(\.diffKey) == ["Claude Code/prisma"],
            "a still-declared server was reported as removed rather than stopped")

        // MARK: Attribution only when the experiment was clean
        expect(
            comparison.attributable == nil,
            "a delta was attributed to one server while two changed")
        let clean = ContextComparison(
            before: ContextSnapshot(
                takenAt: Date(timeIntervalSinceNow: -3600), fixedPrefixTokens: 40000,
                servers: [gone], turnsObserved: 100),
            afterPrefixTokens: 35000, afterServers: [], turnsSince: 50)
        expect(
            clean.attributable?.tokens == 5000,
            "a single-server removal did not attribute its delta")
        let wrongSign = ContextComparison(
            before: ContextSnapshot(
                takenAt: Date(timeIntervalSinceNow: -3600), fixedPrefixTokens: 30000,
                servers: [gone], turnsObserved: 100),
            afterPrefixTokens: 35000, afterServers: [], turnsSince: 50)
        expect(
            wrongSign.attributable == nil,
            "a removal was credited with a delta that moved the wrong way")

        // MARK: This machine, right now
        //
        // Informational rather than pass/fail: a machine with no agent running
        // has nothing to identify, and that is not a bug.
        let live = MCPRegistry.fromDisk()
        let byClient = Dictionary(grouping: live.declarations, by: \.client)
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
        lines.append("Config on this machine:")
        for (client, count) in byClient {
            lines.append("  \(client) — \(count) declarations")
        }
        if live.declarations.isEmpty {
            lines.append("  none found — the join has nothing to work with here")
        }
        lines.append("")

        if failures.isEmpty {
            lines.append("Join intact.")
        } else {
            lines.append("\(failures.count) check\(failures.count == 1 ? "" : "s") failed:")
            for failure in failures { lines.append("  · \(failure)") }
        }
        return (lines, failures.isEmpty)
    }

    private static func target(pid: pid_t, title: String, declarationKey: String?) -> Target {
        Target(
            id: "pid-\(pid)", handle: .process(pid), kind: .mcpServer,
            title: title, subtitle: "", evidence: "self-test",
            declarationKey: declarationKey)
    }
}
