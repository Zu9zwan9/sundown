import Foundation

/// Measured token usage, read from agent session transcripts on this machine.
///
/// This exists because the alternative was worse. `ContextCost` multiplies a
/// per-server constant by a server count, and that constant was a guess — a
/// plausible-looking number nobody had measured. Guesses presented as forecasts
/// are how tools lose trust.
///
/// Agent CLIs write JSONL transcripts locally, and every assistant turn carries
/// the request's real token accounting. That turns the whole question from
/// estimation into arithmetic over observed data.
///
/// **Nothing here leaves the machine.** These files contain the user's
/// conversations. Sundown reads token counts and timestamps and ignores message
/// content entirely — see `Turn`, which has nowhere to put text.
public struct TranscriptMetrics: Sendable {

    /// One assistant turn's token accounting. Deliberately holds no content.
    public struct Turn: Sendable, Hashable {
        public let input: Int
        public let cacheCreation: Int
        public let cacheRead: Int
        public let output: Int
        public let timestamp: Date?

        /// Everything the model had to read to answer. The number that matters
        /// for context pressure, as opposed to billing.
        public var totalInput: Int { input + cacheCreation + cacheRead }

        public init(
            input: Int, cacheCreation: Int, cacheRead: Int, output: Int, timestamp: Date? = nil
        ) {
            self.input = input
            self.cacheCreation = cacheCreation
            self.cacheRead = cacheRead
            self.output = output
            self.timestamp = timestamp
        }
    }

    /// What one server actually cost by being *used*, as opposed to merely
    /// being connected.
    ///
    /// Attribution here is exact rather than inferred: MCP tool names carry
    /// their server in the name (`mcp__<server>__<tool>`), so a call and its
    /// result can be charged to the right server with no guessing. That is the
    /// opposite of the fixed prefix, which arrives as one undifferentiated
    /// number and cannot be split without an experiment.
    public struct ServerUsage: Sendable, Hashable {
        public let server: String
        public let calls: Int
        /// Characters of tool-result payload fed back into the conversation.
        public let resultCharacters: Int

        public init(server: String, calls: Int, resultCharacters: Int) {
            self.server = server
            self.calls = calls
            self.resultCharacters = resultCharacters
        }

        /// Results are JSON, which runs denser than prose. Four characters per
        /// token is the usual rule of thumb and it is an approximation — the
        /// real tokenizer is not something Sundown can run offline, and this
        /// number is reported as "~" everywhere it appears.
        public var approximateTokens: Int { resultCharacters / 4 }

        public var averageTokensPerCall: Int { calls > 0 ? approximateTokens / calls : 0 }
    }

    public let turns: [Turn]
    public let sessionCount: Int
    public let serverUsage: [ServerUsage]
    /// The leanest turn of each session, one entry per session.
    public let sessionFloors: [Int]

    public init(
        turns: [Turn],
        sessionCount: Int,
        serverUsage: [ServerUsage] = [],
        sessionFloors: [Int] = []
    ) {
        self.turns = turns
        self.sessionCount = sessionCount
        self.serverUsage = serverUsage
        self.sessionFloors = sessionFloors
    }

    public var isEmpty: Bool { turns.isEmpty }

    /// Servers ranked by what their results cost, heaviest first.
    public var serversByCost: [ServerUsage] {
        serverUsage.sorted { $0.resultCharacters > $1.resultCharacters }
    }

    public var totalActiveTokens: Int {
        serverUsage.reduce(0) { $0 + $1.approximateTokens }
    }

    // MARK: - The fixed tax

    /// The smallest complete input any turn required — the floor of every
    /// request in the session.
    ///
    /// Why the minimum is the right estimator: a conversation only grows. The
    /// leanest turn is the earliest one, whose input is the system prompt plus
    /// tool definitions plus almost nothing else. That prefix is re-read on
    /// every subsequent request, so it is exactly the standing charge for
    /// having servers connected.
    ///
    /// It is a **lower bound**, and deliberately so. Some of it is the system
    /// prompt rather than tool schemas, and Sundown cannot separate the two
    /// from the outside. Reporting a floor that is certainly paid beats
    /// reporting an attribution that might be invented.
    /// The **median** of the per-session floors, not the global minimum.
    ///
    /// The global minimum was right while every transcript came from one agent
    /// and wrong the moment they didn't. Sub-agent sessions run with a fraction
    /// of the parent's system prompt, so one 20-token turn in a side session
    /// dragged the reported standing charge from ~39,000 to 20 — and printed
    /// "0% of a 200,000-token window", which is the kind of obviously-broken
    /// output that at least fails loudly.
    ///
    /// A prefix is a property of a session, so it has to be measured per
    /// session first. The median then resists both the tiny sub-agent and the
    /// one enormous outlier, which a mean would not.
    public var fixedPrefixTokens: Int {
        if !sessionFloors.isEmpty {
            let sorted = sessionFloors.sorted()
            return sorted[sorted.count / 2]
        }
        // Directly-constructed metrics (tests, single sessions) have no
        // per-session breakdown; the whole set is one session.
        return turns.map(\.totalInput).filter { $0 > 0 }.min() ?? 0
    }

    /// The largest input any single turn required — how big it got by the end.
    public var peakInputTokens: Int {
        turns.map(\.totalInput).max() ?? 0
    }

    public var medianInputTokens: Int {
        let sorted = turns.map(\.totalInput).sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    /// Total read back out of cache across every turn observed.
    ///
    /// Reported separately from a cost figure on purpose: cached reads are
    /// billed at a fraction of fresh input, so treating this as spend would
    /// overstate it. It measures context pressure, not money.
    public var totalCacheRead: Int { turns.reduce(0) { $0 + $1.cacheRead } }
    public var totalCacheCreation: Int { turns.reduce(0) { $0 + $1.cacheCreation } }
    public var totalOutput: Int { turns.reduce(0) { $0 + $1.output } }

    /// Turns per day across the observed window, for projecting the fixed cost.
    ///
    /// Returns nil rather than a fabricated rate when the transcripts don't
    /// span enough time to support the division.
    public var turnsPerDay: Double? {
        let stamps = turns.compactMap(\.timestamp).sorted()
        guard let first = stamps.first, let last = stamps.last else { return nil }
        let days = last.timeIntervalSince(first) / 86_400
        guard days >= 0.5 else { return nil }
        return Double(turns.count) / days
    }

    /// What the standing charge costs per day at the observed rate.
    public var projectedDailyFixedTokens: Int? {
        guard let rate = turnsPerDay else { return nil }
        return Int(Double(fixedPrefixTokens) * rate)
    }

    public func windowShare(contextWindow: Int) -> Double {
        guard contextWindow > 0 else { return 0 }
        return Double(fixedPrefixTokens) / Double(contextWindow)
    }
}

// MARK: - Reading them

extension TranscriptMetrics {

    /// Where agent CLIs keep session transcripts.
    ///
    /// Both are checked because Claude Code writes to the first and
    /// plugin-hosted runs land under the second. Unknown layouts are skipped
    /// rather than guessed at.
    public static func defaultSearchRoots() -> [URL] {
        var roots: [URL] = []

        // Escape hatch for unusual layouts, and what the integration tests use
        // to aim at a known directory.
        if let override = ProcessInfo.processInfo.environment["SUNDOWN_TRANSCRIPT_ROOT"] {
            roots.append(URL(fileURLWithPath: override))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent(".claude/projects"))

        // Plugin-hosted sessions live under the per-user temp directory.
        //
        // NSTemporaryDirectory() rather than the TMPDIR environment variable:
        // TMPDIR is unset in launchd-spawned processes and in some shells, and
        // reading it directly meant those sessions were silently invisible —
        // the report looked healthy while measuring a completely different set
        // of transcripts than the user assumed. NSTemporaryDirectory() falls
        // back to the confstr per-user path, which is always there.
        roots.append(
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("claude-hostloop-plugins")
        )

        var seen = Set<String>()
        return
            roots
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Parse every transcript under the given roots, newest first.
    ///
    /// - Parameter limit: how many session files to read. Transcripts reach
    ///   tens of megabytes, and the marginal value of the 40th session is low,
    ///   so this is capped by default rather than reading an unbounded amount
    ///   of the user's disk on a menu-bar refresh.
    /// - Parameter since: ignore turns older than this. The snapshot workflow
    ///   depends on it: after you disconnect a server, only sessions that ran
    ///   *afterwards* say anything about the new cost, and folding in the old
    ///   ones would bury the change you are trying to see.
    public static func load(
        roots: [URL]? = nil,
        limit: Int = 12,
        since: Date? = nil
    ) -> TranscriptMetrics {
        let searchRoots = roots ?? defaultSearchRoots()
        let files = transcriptFiles(under: searchRoots, limit: limit)

        var turns: [Turn] = []
        var calls: [String: Int] = [:]
        var characters: [String: Int] = [:]
        var floors: [Int] = []

        for file in files {
            let parsed = parse(file)

            // A turn with no timestamp cannot be placed in time. Dropping it is
            // the conservative choice — keeping it would let pre-change data
            // leak into a post-change measurement and quietly flatten the delta.
            let kept =
                since.map { cutoff in
                    parsed.turns.filter { ($0.timestamp ?? .distantPast) >= cutoff }
                } ?? parsed.turns

            guard !kept.isEmpty else { continue }

            // The floor is per session, computed before everything is pooled —
            // see `fixedPrefixTokens` for why pooling first gives the wrong
            // answer as soon as more than one agent is involved.
            if let floor = kept.map(\.totalInput).filter({ $0 > 0 }).min() {
                floors.append(floor)
            }

            turns.append(contentsOf: kept)
            for (server, count) in parsed.calls { calls[server, default: 0] += count }
            for (server, chars) in parsed.resultCharacters {
                characters[server, default: 0] += chars
            }
        }

        let usage = calls.map { server, count in
            ServerUsage(
                server: server,
                calls: count,
                resultCharacters: characters[server] ?? 0
            )
        }

        return TranscriptMetrics(
            turns: turns,
            // Sessions that contributed data, not files on disk — with a
            // `since` cutoff most files legitimately contribute nothing.
            sessionCount: floors.count,
            serverUsage: usage,
            sessionFloors: floors
        )
    }

    /// Adds each root's symlinked children as roots in their own right.
    ///
    /// Plugin hosts don't copy session directories into the temp tree — they
    /// symlink them, one per session. `FileManager.enumerator` does not follow
    /// symlinks (nor does `find` without `-L`), so every plugin-hosted
    /// transcript was invisible while the report cheerfully described the other
    /// agent's sessions instead. Wrong data is worse than missing data, because
    /// it doesn't look wrong.
    ///
    /// Capped and sorted by recency: a long-lived machine accumulates hundreds
    /// of these, most pointing at directories that no longer exist, and walking
    /// them all would make a menu-bar refresh visibly slow.
    static func expandingSymlinks(in roots: [URL], maximum: Int = 24) -> [URL] {
        let fm = FileManager.default
        var expanded: [(URL, Date)] = []
        var seen = Set<String>()

        for root in roots {
            if seen.insert(root.standardizedFileURL.path).inserted {
                expanded.append((root, .distantFuture))  // declared roots always win
            }
            guard
                let children = try? fm.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            for child in children {
                let values = try? child.resourceValues(
                    forKeys: [.isSymbolicLinkKey, .contentModificationDateKey])
                guard values?.isSymbolicLink == true else { continue }

                let resolved = child.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                guard
                    fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                    isDirectory.boolValue,
                    seen.insert(resolved.standardizedFileURL.path).inserted
                else { continue }

                expanded.append((resolved, values?.contentModificationDate ?? .distantPast))
            }
        }

        return expanded.sorted { $0.1 > $1.1 }.prefix(maximum).map(\.0)
    }

    /// - Parameter limit: newest N **per root**, not N overall.
    ///
    /// Taking the newest N globally looked equivalent and wasn't. One agent
    /// writing frequently starves the other entirely: 40 busy Claude Code
    /// transcripts crowded out every plugin-hosted session, and the report
    /// confidently described a workload the user wasn't asking about. Per-root
    /// sampling costs a few more files and guarantees every source is seen.
    static func transcriptFiles(under roots: [URL], limit: Int) -> [URL] {
        let fm = FileManager.default
        var selected: [(URL, Date)] = []

        for root in expandingSymlinks(in: roots) {
            var found: [(URL, Date)] = []
            guard
                let walker = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                found.append((url, values?.contentModificationDate ?? .distantPast))
            }

            selected.append(contentsOf: found.sorted { $0.1 > $1.1 }.prefix(limit))
        }

        // Roots can overlap (an override pointing inside a default root), and
        // counting a transcript twice would double every total.
        var seen = Set<String>()
        return
            selected
            .sorted { $0.1 > $1.1 }
            .filter { seen.insert($0.0.standardizedFileURL.path).inserted }
            .map(\.0)
    }

    /// Pull token accounting out of one JSONL transcript.
    ///
    /// Line-by-line rather than loading the file: these run to tens of MB, and
    /// a menu-bar app has no business holding that in memory to read integers
    /// out of it.
    struct ParsedTranscript {
        var turns: [Turn] = []
        var calls: [String: Int] = [:]
        var resultCharacters: [String: Int] = [:]
    }

    static func parse(_ url: URL) -> ParsedTranscript {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ParsedTranscript()
        }
        defer { try? handle.close() }

        var result = ParsedTranscript()
        var turns: [Turn] = []
        var seen = Set<String>()
        var remainder = Data()

        // A tool_result names only the call it answers, so the server has to be
        // remembered from the tool_use that opened it.
        var callOwner: [String: String] = [:]

        /// Bytes a tool result contributed, without ever handing a bare value
        /// to JSONSerialization.
        func resultSize(_ payload: Any?) -> Int {
            switch payload {
            case let string as String:
                return string.utf8.count
            case let number as NSNumber:
                return number.stringValue.utf8.count
            case let value?:
                guard JSONSerialization.isValidJSONObject(value),
                    let data = try? JSONSerialization.data(withJSONObject: value)
                else { return 0 }
                return data.count
            default:
                return 0
            }
        }

        /// `mcp__<server>__<tool>` — anything else is a built-in tool and none
        /// of Sundown's business.
        func serverName(fromToolName name: String) -> String? {
            guard name.hasPrefix("mcp__") else { return nil }
            let parts = name.components(separatedBy: "__")
            guard parts.count >= 3, !parts[1].isEmpty else { return nil }
            return parts[1]
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()

        func ingest(_ line: Data) {
            guard !line.isEmpty else { return }
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any]
            else { return }

            // `usage` sits on message.usage for assistant turns; some
            // writers hoist it to the top level.
            let message = object["message"] as? [String: Any]

            // Tool traffic first: it lives on both assistant and user records,
            // and only assistant records carry `usage`, so an early return
            // below would lose every tool_result.
            if let blocks = message?["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "tool_use":
                        guard
                            let name = block["name"] as? String,
                            let server = serverName(fromToolName: name)
                        else { continue }
                        result.calls[server, default: 0] += 1
                        if let id = block["id"] as? String { callOwner[id] = server }

                    case "tool_result":
                        guard
                            let id = block["tool_use_id"] as? String,
                            let server = callOwner.removeValue(forKey: id)
                        else { continue }
                        // Measure the serialized payload — that is what gets
                        // fed back into the conversation, whatever its shape.
                        //
                        // The string case is checked first, and not only
                        // because it's common: JSONSerialization *raises an
                        // ObjC exception* for a non-collection top-level value
                        // rather than throwing a Swift error, so `try?` does
                        // not catch it and the process dies. `isValidJSONObject`
                        // is the only safe way to ask.
                        result.resultCharacters[server, default: 0] += resultSize(block["content"])

                    default:
                        continue
                    }
                }
            }

            guard
                let usage = (message?["usage"] as? [String: Any])
                    ?? (object["usage"] as? [String: Any])
            else { return }

            let input = usage["input_tokens"] as? Int ?? 0
            let creation = usage["cache_creation_input_tokens"] as? Int ?? 0
            let read = usage["cache_read_input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            guard input + creation + read > 0 else { return }

            // Streaming writes the same turn more than once. Counting a turn
            // twice would inflate every total downstream, and the duplicates
            // are byte-identical, so the id plus the counts is a sufficient key.
            let id =
                (object["uuid"] as? String)
                ?? (message?["id"] as? String)
                ?? "\(input):\(creation):\(read):\(output)"
            guard seen.insert(id).inserted else { return }

            let stampString = object["timestamp"] as? String
            let stamp = stampString.flatMap {
                formatter.date(from: $0) ?? plainFormatter.date(from: $0)
            }

            turns.append(
                Turn(
                    input: input,
                    cacheCreation: creation,
                    cacheRead: read,
                    output: output,
                    timestamp: stamp
                )
            )
        }

        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            var buffer = remainder + chunk
            while let newline = buffer.firstIndex(of: 0x0A) {
                ingest(Data(buffer[buffer.startIndex..<newline]))
                buffer = buffer[buffer.index(after: newline)...]
            }
            remainder = Data(buffer)
        }

        // The tail. A transcript being written right now has no trailing
        // newline, so skipping this dropped the most recent turn of every live
        // session — the one most worth seeing.
        ingest(remainder)

        result.turns = turns
        return result
    }
}

// MARK: - Saying it plainly

extension TranscriptMetrics {

    /// The report, written so each line can be checked against the data.
    public func explanation(contextWindow: Int = 200_000, serverCount: Int? = nil) -> [String] {
        guard !isEmpty else {
            return [
                "No transcripts found, so there is nothing measured to report.",
                "Run `sundown --context --tokens-per-server N` for the estimate instead.",
            ]
        }

        var lines: [String] = [
            "Measured from \(sessionCount) session\(sessionCount == 1 ? "" : "s"), "
                + "\(turns.count.formatted()) turns:",
            "",
            "  \(fixedPrefixTokens.formatted()) tokens — standing charge on every request",
            "    (leanest turn observed: system prompt + tool definitions)",
            "  \(medianInputTokens.formatted()) tokens — median request",
            "  \(peakInputTokens.formatted()) tokens — largest request",
        ]

        lines.append(
            "  \(Int(windowShare(contextWindow: contextWindow) * 100))% of a "
                + "\(contextWindow.formatted())-token window is gone before you type"
        )

        if let daily = projectedDailyFixedTokens, let rate = turnsPerDay {
            lines.append(
                "  ≈ \(daily.formatted()) tokens/day of standing charge "
                    + "at \(Int(rate)) turns/day"
            )
        }

        if let servers = serverCount, servers > 0 {
            lines.append("")
            lines.append(
                "  \(servers) servers connected → ~\((fixedPrefixTokens / servers).formatted()) "
                    + "tokens each, if the prefix were all tool definitions."
            )
            lines.append(
                "  It isn't — the system prompt is in there too, so treat that as a ceiling."
            )
        }

        lines.append("")
        lines.append(
            "  Cache: \(totalCacheRead.formatted()) read, "
                + "\(totalCacheCreation.formatted()) written."
        )
        lines.append(
            "  Cached reads bill well below fresh input, so this is context pressure, not spend."
        )

        return lines
    }
}
