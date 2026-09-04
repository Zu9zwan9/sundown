import Foundation

/// What your MCP servers cost you in context, whether or not you use them.
///
/// This is the honest half of "forecast my token usage". Sundown cannot see
/// your API spend — it watches processes, not requests, and anything it told
/// you about dollars would be invented.
///
/// What it *can* reason about is real and usually larger: every connected MCP
/// server injects its tool definitions into the context window of **every
/// message you send**, used or not. Ten idle servers are not free; they are a
/// fixed tax on each turn. That is the cost people feel and can't see.
///
/// The model is deliberately transparent arithmetic rather than a black box,
/// because the per-server constant is an estimate and the user should be able
/// to see exactly what it multiplied.
public struct ContextCost: Sendable {

    /// Estimated tokens a single server's tool definitions add to each request.
    ///
    /// **This default is an unverified estimate and should be calibrated.**
    /// Tool schemas vary enormously — a one-tool server might cost 200 tokens,
    /// a filesystem server with a dozen richly-described tools several
    /// thousand. Shipping a precise-looking number nobody measured would be
    /// worse than shipping the arithmetic and saying so.
    ///
    /// See `calibrationInstructions` for how to replace it with a real one.
    public static let defaultTokensPerServer = 800

    public let serverCount: Int
    public let tokensPerServer: Int
    /// Turns per day, for projecting the fixed cost into something legible.
    public let requestsPerDay: Int

    public init(
        serverCount: Int,
        tokensPerServer: Int = ContextCost.defaultTokensPerServer,
        requestsPerDay: Int = 200
    ) {
        self.serverCount = serverCount
        self.tokensPerServer = tokensPerServer
        self.requestsPerDay = requestsPerDay
    }

    /// Fixed overhead added to every single request.
    public var tokensPerRequest: Int { serverCount * tokensPerServer }

    /// Projected daily overhead from having these servers connected at all.
    public var tokensPerDay: Int { tokensPerRequest * requestsPerDay }

    /// Share of a context window consumed before you have typed anything.
    public func windowShare(contextWindow: Int) -> Double {
        guard contextWindow > 0 else { return 0 }
        return Double(tokensPerRequest) / Double(contextWindow)
    }

    /// What ending the idle ones would give back.
    public func saving(byEnding count: Int) -> ContextCost {
        ContextCost(
            serverCount: max(0, serverCount - count),
            tokensPerServer: tokensPerServer,
            requestsPerDay: requestsPerDay
        )
    }

    /// The arithmetic, written out. Shown instead of a single confident
    /// number, so the estimate can be argued with.
    public func explanation(contextWindow: Int = 200_000) -> [String] {
        [
            "\(serverCount) connected servers × ~\(tokensPerServer) tokens of tool definitions",
            "= ~\(tokensPerRequest.formatted()) tokens on every request, before you type anything",
            "= ~\(Int(windowShare(contextWindow: contextWindow) * 100))% of a \(contextWindow.formatted())-token window",
            "≈ \(tokensPerDay.formatted()) tokens/day at \(requestsPerDay) turns",
            "Per-server figure is an estimate — see `sundown --calibrate` to measure yours.",
        ]
    }

    public static let calibrationInstructions = """
        Calibrating the per-server token estimate
        -----------------------------------------
        You probably don't need to. `sundown --context` reads the session
        transcripts your agent CLI already writes and reports what your requests
        actually cost — measured, not modelled. Try that first.

        This estimate is the fallback for machines with no transcripts to read.
        The 800-token default is a placeholder and has been observed to understate
        reality by roughly 5x on a machine running ten servers, so do not make
        decisions on it without checking.

        If you are stuck with the estimate:

          1. In Claude Code, run /context and note the tool-definition total.
          2. Divide by the number of connected MCP servers.
          3. Pass it back:  sundown --tokens-per-server <N>

        A caution that applies to both paths: the fixed prefix is the system
        prompt *plus* tool definitions, and nothing outside the agent can tell
        you where one ends and the other begins. Per-server figures are ceilings.
        """
}
