# Sundown — market research

Researched August 2026. Sources at the end.

> **Two corrections, later verified.** (1) The "seven open issues" line below
> was already wrong when published — several had closed, the earliest in
> December 2025. (2) The competitive set is missing
> [antiburn](https://github.com/antiburn/antiburn), which did not exist when
> this was written and now ships the unused-server detection this document
> treats as unoccupied. Read
> `strategy/validation/evidence-update-2026-09-18.md` before citing anything
> here.

## The finding that matters most

**The problem is real, severe, and cross-vendor. The business is probably not.**

Every vendor whose agent tooling spawns MCP servers has an open, unresolved
bug for exactly what Sundown cleans up. And every one of those bug threads
contains the upstream fix that would make Sundown unnecessary. Read that
tension first; everything below is detail.

## The problem is documented, not hypothetical

Seven open issues on `anthropics/claude-code` alone describe orphaned MCP
processes: [#1935](https://github.com/anthropics/claude-code/issues/1935),
[#11778](https://github.com/anthropics/claude-code/issues/11778),
[#15211](https://github.com/anthropics/claude-code/issues/15211),
[#19201](https://github.com/anthropics/claude-code/issues/19201),
[#22612](https://github.com/anthropics/claude-code/issues/22612),
[#39170](https://github.com/anthropics/claude-code/issues/39170),
[#40667](https://github.com/anthropics/claude-code/issues/40667).

It is not a Claude problem. The same failure has its own issue on
[GitHub Copilot CLI](https://github.com/github/copilot-cli/issues/2279), on
[OpenAI Codex](https://github.com/openai/codex/issues/37402), in the
[Cursor forum](https://forum.cursor.com/t/mcp-process-leak-orphaned-children-on-restart/156478),
and on [Google Antigravity](https://discuss.ai.google.dev/t/bug-all-mcp-server-processes-are-orphaned-after-conversation-ends-accumulate-indefinitely-causing-system-memory-exhaustion/139866).

That breadth is the single best signal here. The cause is structural — stdio
MCP servers are children whose parent exits without signalling them — so it
reproduces anywhere the pattern is used, regardless of vendor.

Reported severity is worse than "some idle RAM":

- Orphaned `bun` MCP processes spin at **100% CPU each, indefinitely**
  ([#39170](https://github.com/anthropics/claude-code/issues/39170)).
- Idle MCP servers each hold **1–2% CPU** continuously.
- One developer wrote up
  [Claude Code consuming 14 GB of RAM](https://dev.to/thestack_ai/i-built-a-zombie-process-killer-because-claude-code-ate-14gb-of-my-ram-1deg)
  and shipped a zombie-process killer in response.
- Docker-based MCP servers leak whole containers, because a closed stdin pipe
  is not a signal and `docker run` never gets to tell the daemon to stop
  ([FutureSearch](https://futuresearch.ai/blog/mcp-leaks-docker-containers/)).

Sundown's container handling and its `ppid == 1` orphan detection were built
against exactly this behaviour before the research confirmed it. That's
reassuring about the design and says nothing about the market.

## Who already occupies this shelf

| Tool | Angle | Price |
| --- | --- | --- |
| [PortKiller](https://github.com/gupsammy/PortKiller) | Dev ports; splits processes / Docker / Homebrew services | Free, open source |
| [macos-port-killer](https://github.com/shaneholloman/macos-port-killer) | Ports, native menu bar | Free, open source |
| [Node Killer](https://github.com/adolfoflores/node-killer) | Node / Vite / Bun dev servers | Free, open source |
| [Port Kill](https://alternativeto.net/software/port-kill/about) | Ports 2000–6000, kill-all | Free |
| [RAMBar](https://maxghenis.com/blog/rambar/) | Memory across Claude Code sessions, VS Code, Chrome, Python | Free |

Two things follow.

**The shelf is crowded but aimed elsewhere.** Every one of these is organised
around a *port* or a *number*. They answer "what is on 3000" and "what is
eating RAM." None answer "what did my session leave behind." A port-centric
tool cannot see an MCP server that holds no port, which is most of them —
stdio transport is the default.

**RAMBar is the nearest thing and still isn't it.** It already tracks Claude
Code sessions specifically, which proves someone else saw the same signal. But
it monitors; it doesn't end anything, and it doesn't group a subtree or name
`filesystem` instead of a 140-character node invocation.

So the wedge is real and narrow: **session-scoped semantics.** Grouping a
subtree under the thing that spawned it, naming servers the way their config
names them, showing why each row was flagged, refusing to touch the client
app. That is what none of the incumbents do.

## Why it is probably not a business anyway

Three reasons, in order of severity.

**1. The upstream fix is already specified.** The issue threads propose
spawning MCP servers in a shared process group, propagating SIGTERM on
shutdown, adding a parent-liveness watchdog, and detecting orphans from prior
sessions at startup. Any vendor shipping any one of those removes most of the
need. This is not a moat with a timeline; it is a countdown of unknown length.
The specific proposal "detect and offer to kill orphaned processes from
previous sessions on startup" *is Sundown*, proposed as a built-in feature.

**2. Free open-source competitors already own the adjacent job.** The
[2026 read on Mac utilities](https://standro.app/article-one-time-purchase-mac-apps)
is that open-source has caught up with or passed the paid original for most
simple utilities, and the paid ones that survive do something free tools
can't — Hazel's automation, BetterTouchTool's gestures. "Kills processes
better" is not in that category.

**3. The price ceiling is low and the audience is small.** Menu bar utilities
cluster at [$9.99 and below, one-time](https://teenyapps.com/articles/best-mac-apps-under-10-dollars/),
and indie Mac developers increasingly
[sell direct rather than pay Apple 30%](https://thesweetbits.com/we-asked-indie-mac-developers-about-ship-outside-the-app-store/).
The addressable audience is macOS developers who run agentic tooling heavily
enough to notice — real, growing, and still small. At $9 one-time against a
free PortKiller, the arithmetic doesn't reach a salary.

## What to do instead

**Ship it free and open source.** The cost structure supports it: local-only,
no server, no sync, marginal cost per user near zero. The return is
reputation and distribution among exactly the developers who hit this daily,
in a moment when several vendors are publicly failing at it. That is worth
more right now than a few hundred dollars of license revenue.

**Keep the CLI on the roadmap and treat it as the real product.** `sundown
--dry-run` in a shell `trap EXIT` or a Claude Code hook solves the problem
without anyone opening a panel. It also ports to Linux, where the CI and
devcontainer version of this problem is worse and entirely unserved. The GUI
is the demo; the CLI is the thing people wire in and keep.

**Do not build a paid team or fleet product on this.** If orphan cleanup
becomes a business, it becomes a feature of an agent-observability platform —
which is a different, much larger product with a different set of reasons to
exist. Reaching it from here means abandoning what makes Sundown good.

**Watch for the shutdown signal.** If Anthropic, OpenAI, or Cursor ships
process-group cleanup, the MCP category collapses and what remains is a
better-designed port killer in a crowded free field. That is the moment to
stop investing, and it is worth deciding now what it would look like rather
than discovering it later.

## What I could not establish

- **Real usage numbers.** No download counts, stars over time, or revenue for
  any competitor. Everything above is inferred from issue volume and public
  positioning, not from demand data.
- **Willingness to pay.** No pricing test, no survey, no waitlist. The
  argument against a paid product is a structural one, not an empirical one.
- **Whether any vendor has scheduled a fix.** The issues are open; none of the
  threads I found carried a committed fix or milestone. Absence of evidence
  here is genuinely weak evidence.

## Sources

- [claude-code #1935 — MCP servers not properly terminated on exit](https://github.com/anthropics/claude-code/issues/1935)
- [claude-code #11778 — `claude mcp list` causes orphaned processes](https://github.com/anthropics/claude-code/issues/11778)
- [claude-code #15211 — Windows: MCP child processes not cleaned up](https://github.com/anthropics/claude-code/issues/15211)
- [claude-code #19201 — Claude Desktop macOS leaves orphaned CLI processes](https://github.com/anthropics/claude-code/issues/19201)
- [claude-code #22612 — Orphaned MCP servers not cleaned up when sessions end](https://github.com/anthropics/claude-code/issues/22612)
- [claude-code #39170 — MCP bun processes orphaned, peg CPU at 100%](https://github.com/anthropics/claude-code/issues/39170)
- [claude-code #40667 — MCP leak after subagent/session termination](https://github.com/anthropics/claude-code/issues/40667)
- [copilot-cli #2279 — Orphaned MCP processes accumulate indefinitely](https://github.com/github/copilot-cli/issues/2279)
- [codex #37402 — MCP fleet kill/respawn cycles](https://github.com/openai/codex/issues/37402)
- [Cursor forum — MCP process leak / orphaned children on restart](https://forum.cursor.com/t/mcp-process-leak-orphaned-children-on-restart/156478)
- [Google Antigravity — All MCP processes orphaned after conversation ends](https://discuss.ai.google.dev/t/bug-all-mcp-server-processes-are-orphaned-after-conversation-ends-accumulate-indefinitely-causing-system-memory-exhaustion/139866)
- [FutureSearch — How to stop MCP servers leaving orphaned Docker containers](https://futuresearch.ai/blog/mcp-leaks-docker-containers/)
- [DEV — I built a zombie process killer because Claude Code ate 14GB of my RAM](https://dev.to/thestack_ai/i-built-a-zombie-process-killer-because-claude-code-ate-14gb-of-my-ram-1deg)
- [DEV — macOS runs out of application memory because your dead dev servers never die](https://dev.to/mjmirza/macos-runs-out-of-application-memory-because-your-dead-dev-servers-never-die-4h3c)
- [PortKiller](https://github.com/gupsammy/PortKiller/) · [macos-port-killer](https://github.com/shaneholloman/macos-port-killer) · [Node Killer](https://github.com/adolfoflores/node-killer) · [Port Kill](https://alternativeto.net/software/port-kill/about) · [RAMBar](https://maxghenis.com/blog/rambar/)
- [Best Mac apps under $10, one-time purchase](https://teenyapps.com/articles/best-mac-apps-under-10-dollars/)
- [Why one-time purchase Mac apps still exist in 2026](https://standro.app/article-one-time-purchase-mac-apps)
- [Indie Mac developers on shipping outside the App Store](https://thesweetbits.com/we-asked-indie-mac-developers-about-ship-outside-the-app-store/)
