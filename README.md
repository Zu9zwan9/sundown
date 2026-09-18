# Sundown

```
Since Aug 14, 2026, across 5,636 new turns:

  before: 39,358 tokens
  now:    92,622 tokens
  cost:   53,264 more tokens on every request
```

That is one real Mac. Every connected MCP server injects its tool definitions
into **every message you send**, called or not, and over three weeks this
machine's standing charge more than doubled without anyone deciding it should.

Sundown measures that charge, tells you which of those servers you never
actually call, and ends what your sessions left running.

```
5 of 13 connected servers were never called across 122 sessions:

  · elevenlabs
  · mcp-unframer-co
  · playwright
  · plugin:aws-startup-advisor:aws-pricing-calculator
  · plugin:aws-startup-advisor:awspricing

  They still load on every request — roughly 35,620 tokens of your
  92,622-token standing charge.
```

Free, open source, entirely local. It reads token counts and timestamps from
transcripts your agent already wrote, and never message content.

## Install

```bash
brew install Zu9zwan9/sundown/sundown
```

Or run it once without installing anything:

```bash
npx sundown-cli --idle
```

macOS 14+. The npm package is named `sundown-cli` because `sundown` on npm is
[Ionică Bizău's sunrise/sunset calculator](https://www.npmjs.com/package/sundown),
published since 2018. The command is still `sundown`.

## The three commands

```bash
sundown --idle       # servers you pay for on every request and never call
sundown --snapshot   # record today's standing charge and server set
sundown --compare    # what changed since — this is how you price one server
```

`--snapshot`, disconnect one server, use the agent for a session or two,
`--compare`. That is an experiment on your own workload, so the number is
yours rather than a benchmark's. Nothing is spawned to measure it — some MCP
servers connect to production systems on startup, and a measuring tool has no
business doing that.

## What this does not replace

**Claude Code already ships `/context`** (standing cost by category) and
**`/usage` Attribution** (recent usage per MCP server). If you use Claude Code
and want either of those numbers, use those. They are first-party, live, and
free.

**[cc-reaper](https://github.com/theQuert/cc-reaper)** (Apache-2.0) already
reaps orphaned Claude Code processes across three layers, and is more thorough
at that specific job than Sundown's teardown.

**[antiburn](https://github.com/antiburn/antiburn)** (free, open source)
reports unused MCP servers from your session transcripts, and does it across
sixteen agents where Sundown reads two. If all you want is to know which
servers you never call, install antiburn — its coverage is better than mine.

**What is left that is actually mine** is narrower than I first claimed:

- **Acting on the answer.** antiburn reports and stops there; cc-reaper ends
  processes but measures nothing. Sundown is the only one that does both, and
  the part that earns a button with no undo is `SafetyGuard` — the rules about
  what must never be touched, and the 104 tests that hold them.
- **`--snapshot` / `--compare`**, to learn what one specific server costs on
  your own workload, measured rather than estimated.

If neither of those is interesting to you, you probably do not need this.

## What it refuses to say

`--idle` tells people to disconnect things, so it abstains far more readily
than it accuses. A server is only called idle when Sundown can match its
process to a declaration in your own config, *and* that declaration's id
appears in transcripts it can actually read. Anything else is reported with the
specific reason it could not be judged:

```
Not judged — no config declaration matches 6 running processes
(aws-pricing, gk mcp --plugin --host=claude, node, pdf, server, wrapper).

Not judged — 2 servers belong to Claude Desktop, whose transcripts
aren't in the folders Sundown reads.

Not counted as idle — a wrong accusation costs more than a miss.
```

The join itself is a rule, not a resemblance: a client turns the key you wrote
in your config into the `mcp__<id>__<tool>` prefix in the transcript by
replacing anything that is not a letter, digit or hyphen with an underscore.
`plugin:aws-startup-advisor:awspricing` becomes
`plugin_aws-startup-advisor_awspricing`. There is no fuzzy name matching
anywhere, because a near-match is how you end up telling someone to disconnect
a server they depend on.

```bash
sundown --self-test    # checks that join on your machine. Exits 1 if it broke.
```

## Ambient, without an app

```bash
brew install --cask swiftbar
cp Scripts/sundown.15m.sh <your SwiftBar plugin folder>
```

SwiftBar names that folder on first launch and shows it under Preferences.

A moon in the menu bar, a number only when there is one, the full report in the
dropdown. The refresh interval is the filename — rename it to change it. The
same file works in [xbar](https://xbarapp.com). Sundown ships no menu bar app of
its own: SwiftBar already is one, and it is better at it.

**Notifications are opt-in and have an honest catch.** `Scripts/install-watch.sh`
installs a launchd job that posts a banner when a session ends and leaves
something behind. It posts through `osascript`, because a bare CLI has no bundle
identity to post a notification with — so the banner is attributed to **Script
Editor**, not to Sundown. That means muting it in System Settings mutes *every*
script on your machine, not just this one. If that trade is wrong for you, use
the SwiftBar plugin and skip the notifications.

## Ending what a session left running

Agents spawn background servers. When a session ends cleanly most shut down;
when it crashes, when you force-quit, when you close the terminal, they don't —
they get adopted by `launchd` and run until you reboot. macOS has no
`prctl(PR_SET_PDEATHSIG)`, so there is no clean upstream fix to wait for.

```bash
sundown                     # list, then end on confirmation
sundown --dry-run           # look first
sundown --phase during      # kill a runaway without losing the session
sundown --json              # for scripts
```

One rule holds throughout: **anything with a living, identified owner is never
selected for you.** If a process's ancestry reaches a running Claude Desktop or
`claude` CLI, it belongs to a session someone is using. It is listed, unselected,
with the reason on the row. Run it mid-session with everything open and it will
select nothing — correctly.

Without `--yes` on a non-TTY it refuses rather than hanging on a prompt nobody
will answer. [`LIFECYCLE.md`](LIFECYCLE.md) has the hook, `trap` and launchd
recipes.

### What it will not touch

Enforced in one place, `SafetyGuard`, and every termination path goes through
it:

- anything with a PID below 100, or owned by another user
- Sundown itself and all its ancestors
- anything inside a `.app`, `.appex` or `.xpc` bundle — this is what stops it
  quitting Claude Desktop, Cursor or your terminal while cleaning up the CLIs
  they spawned
- anything under `/System/` or `/usr/libexec/`
- shells and multiplexers, and container **daemons** (containers are stopped
  through `docker stop`; `dockerd` is never signalled)

Termination is graceful first: `SIGTERM`, three seconds, then `SIGKILL` for
whatever refused. Children before parents, so a supervisor cannot respawn what
was just ended. There is no undo, which is why every row shows its evidence and
uncertain matches start unselected.

## Honest limits

- **The standing charge is a floor, not a split.** It is the leanest turn of
  each session — system prompt plus tool definitions. Nothing outside the agent
  can tell you where the prompt ends and the schemas begin, so per-server
  figures from it are ceilings. `--compare` is the only exact per-server number
  here, and only when one server changed at a time.
- **`--compare` is correlation.** Agent updates and different tool sets move the
  same number. The report says so every time it prints one.
- **Remote MCP servers cannot be judged by the process table.** They hold no
  process, so their absence proves nothing. Sundown excludes them rather than
  reporting them as not running.
- **Some processes hide their `argv`.** Classification then falls back to the
  kernel's 32-character name and the safety guard gets more conservative, which
  occasionally means a real target is not offered. That is the correct direction
  to be wrong in.
- **CPU needs two scans.** The first scan of a run reports no rates; `--phase
  during` takes an extra second and says when rates were unavailable. A
  `cpuPercent` of 0 with `cpuRatesAvailable: false` means unknown, not idle.
- **Nothing is remembered between runs.** No allow list, no "always ignore this"
  — a persistent kill list is a persistent liability until these rules have been
  run against a lot of real machines.
- **Not cross-vendor yet.** Cursor, Windsurf and Zed configs are read, so their
  servers get named and grouped, but the transcript half — the "never called"
  verdict — is written against Claude Code and Claude Desktop. Codex and Gemini
  CLI are not read at all. Supporting them before anyone has used this version
  is guessing.

## Build from source

```bash
swift test                    # 104 tests
swift build -c release
./.build/release/sundown --self-test
```

## Further reading

- [`LIFECYCLE.md`](LIFECYCLE.md) — the three phases, plus hook and launchd recipes.
- [`DISTRIBUTION.md`](DISTRIBUTION.md) — why there is no Mac App Store build.
- [`BUILD.md`](BUILD.md) — how to build it, and where I'd expect it to break.

## Where to take it next

1. **A Linux `ProcessSource`.** `/proc/[pid]/stat` and `/proc/[pid]/cmdline`
   give everything `ProcessSnapshot` needs; the rest of SessionKit already
   builds on Linux. One file, not a port.
2. **Transcript readers for other clients**, once someone has actually used this
   against Claude Code and Claude Desktop.
3. **Idle detection by CPU rather than age.** "No CPU for 40 minutes" beats
   "started 6 hours ago", and the sampling is already there.

MIT.
