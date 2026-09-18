# Strategy — August 2026

A record of what the market research changed, including the parts that
invalidated earlier positioning. Written so a future contributor can see which
claims were tested and which were assumed.

---

## The reversal

Sundown was built as a process cleaner. Measuring context cost started as a
supporting feature. Research says the headline was backwards — but not in the
direction I first guessed.

**First guess, wrong:** "lead with the token meter." The measured standing
charge (67,539 tokens, 33% of a 200k window) felt like the painkiller next to
"frees 171 MB of RAM."

**What killed it:**

- Anthropic already ships this. `/context` prints a per-server MCP token
  breakdown; `/doctor` warns per server above 25k. Both free, both in the box,
  and the 3× over-reporting bug they had was fixed in January 2026.
- **Tool search is on by default in Claude Code.** MCP tools are deferred
  rather than loaded upfront, so the static tax is actively shrinking on the
  largest client. Building a business on a number the platform is deliberately
  driving toward zero is a bad trade.
- At least nine independent per-server token meters exist. Their combined
  traction is under 30 GitHub stars. `mcp-checkup` is nearly the identical
  concept, at 1 star. That is the market saying measurement is a feature.
- Every hosted calculator found is free lead-gen for a gateway. The money in
  this space is in *reducing* the cost, and the reducers have 1,500–2,600 stars
  each (MetaMCP, ToolHive, Docker MCP Gateway, MCPJungle).

**What survived, and is stronger:** the *join*. Cost alone isn't actionable —
every server costs something and you keep the ones you need. Usage alone isn't
either. **Which servers you pay for and never call** is actionable, and
answering it requires the live process table *and* the transcripts.

`/context` can't: it sees what's loaded, never what you used. Transcript
readers can't: they see usage, never what's connected. Sundown reads both.
That's structural, not clever.

> **Correction, 2026-09-18.** It was not the whole moat, and this paragraph
> was wrong within days of being written.
> [antiburn](https://github.com/antiburn/antiburn) — created 2026-08-12, two
> days before the research above — ships transcript-based unused-MCP detection
> across sixteen agents. The reasoning here was scoped to *vendors*, and it
> held for vendors; a third party was never in the argument. What survives is
> the half nobody else does: acting safely on the answer. See
> `strategy/validation/evidence-update-2026-09-18.md`.

---

## Audit: claims tested

| Claim | Verdict | Evidence |
|---|---|---|
| Per-server token meter is a product | **Dead** | Anthropic ships `/context` + `/doctor`; 9 competing tools, <30 stars total |
| Stray-port cleanup is a differentiator | **Dead** | port-killer 5,017★, port-kill 2,036★ — both under a year old |
| Menu bar app is the right first surface | **Dead** | Claude menu-bar launches declining: 161 → 112 → 69 points |
| Session-boundary cleanup is unoccupied | **Holds** | devclean 9★, proc-janitor 6★ — 15 stars of total competition |
| The unclean-exit path has no vendor fix | **Holds, strengthened** | macOS lacks `prctl(PR_SET_PDEATHSIG)`; Claude Code #1935, #15861 (27 GB / 10 h), #22612 all open |
| Cross-tool coverage matters | **Holds** | Each vendor only reaps its own children; no general macOS tool (Activity Monitor, App Tamer, Sensei, Stats) models a session at all |
| Tool-*result* cost is unaddressed | **Holds** | Tool search defers *definitions*; result payloads are untouched by every platform fix |

### The threat worth naming

**ccusage — 17,951 stars.** It already reads the same JSONL, already reports
tool-call distribution, and ships an MCP server. "Which server costs most" is a
feature-sized addition for them, not a new product. Sundown's measurement half
is one of their releases away from commoditisation.

The defensible response is not to out-measure them. It's that ccusage cannot
see the process table, so it cannot compute the join, and it cannot act on the
answer. Sundown should treat measurement as the front door and the *action* as
the product — and should consider interoperating rather than competing on the
read.

---

## Positioning

**Category:** agent hygiene. The term currently returns CI/CD build-agent
results — unclaimed in this sense, and cheap category real estate.

**One line:** the only tool that knows which MCP servers you pay for and never
use, because it's the only one that reads both your processes and your history.

**Ordering, deliberately:**

1. The join — `--idle`. Unique, actionable, one command.
2. Session-end cleanup. Why people keep it installed.
3. Ports. A bullet, never a headline. That fight is lost and it doesn't matter.

---

## Distribution

Measured, not assumed. Show HN median is **3 points**; 49% of posts get ≤2;
only 2% clear 100. A *successful* launch is worth roughly 300 stars in week
one, not 3,000.

Two patterns hold in this exact category:

- **A number in the title outperforms.** "saved 91.8% of my LLM tokens" (156
  pts), "96–99% fewer tokens than native MCP" (146 pts).
- **Another Claude meter underperforms**, and visibly declining.

So: CLI first, Homebrew tap on day one, homebrew-core once past 75 stars (one
decent launch clears it). Menu bar later, as a retention surface, not the
introduction. Treat Show HN as a repeatable lottery ticket with genuinely
different angles rather than a single launch event.

The asset nobody has is **the data itself**. Publishing measurements is what
earned pickup for every comparable project found. A public dataset of what
servers actually cost — and how often they're actually called — costs nothing
to give away and compounds.

---

## Monetisation: the honest ceiling

Free and open source, MIT, positioned for adoption. That decision stands, and
the research says the alternative isn't much of one.

Verified GitHub Sponsors data, August 2026:

| Project | Stars | Sponsors | Reality |
|---|---|---|---|
| AeroSpace | 22,412 | 229 | ~**$890/month**, near best-in-class |
| Stats | 41,201 | 90 | 0.22% conversion |
| Ice | 29,272 | 39 current / 430 past | ~91% lifetime churn |
| Homebrew | 49,163 | — | $246,560 *lifetime*, on 21M installs/month |

Donations do not scale with usage. A top-1% macOS utility yields
$200–1,000/month.

If revenue ever matters, the only patterns with demonstrated indie outcomes are
**free OSS core plus a separate paid app** (Rectangle Pro at $9.99, Proxyman at
$89 perpetual, TablePlus at $79–99) or **free for personal, paid for
commercial** (OrbStack, $8/user/month). Note that per-seat pricing runs against
the grain here — Langfuse and Helicone both advertise unlimited seats as a
differentiator. Metering fits the neighbourhood better than seats.

None of that is a reason to change course now. It's a reason not to expect
sponsorship to fund anything.

---

## Risks

**The static tax is shrinking.** Tool search, code-mode execution, and
progressive-disclosure gateways each cut the pre-prompt cost materially. Bias
the product toward what they *don't* fix: tool-result accumulation, and
processes that outlive their session.

**ccusage could absorb the measurement half.** See above.

**Gateways sit architecturally where curation belongs.** Pomerium, ToolHive and
TrueFoundry already do adjacent work with funding behind them. Sundown should
stay local-only and action-oriented rather than drift toward being a worse
gateway.

**Naming is fragile.** The join depends on matching a process name against a
transcript's server id, and those are assigned by different systems.
`IdleServerReport` demotes anything unmatched to *unknown* rather than
accusing it. That conservatism is load-bearing: one screenshot of "disconnect
this server" about a server somebody depends on costs more trust than the
feature earns.

---

## Not verified

Reddit is inaccessible to the research tooling, so the demand picture there is
unconfirmed rather than absent. Registry server counts are self-reported with
incompatible methodologies and are not comparable. Revenue figures for
Rectangle Pro and Proxyman are secondary-source or founder-entered.
