# Sundown — product requirements

Scope note: `MARKET.md` argues whether this should exist and `POSITIONING.md`
argues who it is for. Neither is repeated here. This document states what the
product must do, what it must refuse to do, and how you can tell whether it
did it.

## The problem, in one paragraph

Every MCP server you connect loads its tool schemas into the prefix of every
request you send, whether you call it or not. The charge is invisible: no
client shows it, no registry publishes it, and the servers that cost the most
are often the ones you connected once and forgot. Separately, stdio servers
outlive the sessions that spawned them, so the set you are paying for drifts
away from the set you meant to have.

## Who it is for

A developer running agent CLIs on macOS with more than a handful of MCP
servers connected. They notice context filling faster than it used to and
cannot find out why. They are comfortable in a terminal and hostile to
anything that phones home.

Not for: teams wanting a dashboard, anyone on Linux or Windows, anyone whose
client is not writing transcripts to disk.

## Requirements

**R1. Name the standing charge.** Report what the connected set costs before
the user types anything, measured from their own transcripts rather than
estimated from schema sizes.

*Acceptance:* `sundown --idle` prints a token figure derived from the session
floor across recent transcripts, and labels it as approximate with the reason.

**R2. Say which servers earn it.** Join declared servers to real call counts
across session history, and name the ones that have never been called.

*Acceptance:* every server listed as never-called has zero `tool_use`
invocations in the transcripts examined. A server whose calls cannot be seen
is not listed as never-called.

**R3. Never accuse when it cannot prove.** A process it cannot match to a
declaration, a server whose client writes transcripts Sundown cannot read, and
a server the user has never exercised are each reported as unjudged, with the
reason, rather than folded into the idle count.

*Acceptance:* the report carries a distinct section per abstention reason, and
the idle count excludes all of them.

**R4. End things safely or not at all.** Never signal a process with a living,
identified owner. Never touch a process outside the user's own uid, below the
lowest killable pid, or in Sundown's own ancestry. Escalate politely: term
before kill, with time in between.

*Acceptance:* the safety guard rejects each of those classes, covered by
tests, and no report path can become an action path without `--yes` on a TTY.

**R5. Measure a change rather than assert one.** The user can record the cost
before a change and compare after.

*Acceptance:* `--snapshot` and `--compare` produce a before/after that names
which servers entered and left the set.

**R6. Stay local.** No network calls, ever. Anything published leaves the
machine because the user typed a command that put it somewhere, not because
the binary decided to.

*Acceptance:* `--contribute` writes to stdout and exits. The binary opens no
socket.

## Non-goals

1. **No daemon.** A tool that fixes background processes does not get to be
   one. Sundown runs when invoked and exits.
2. **No GUI.** The menu bar app was 1,117 lines of SwiftUI removed on
   2026-09-18 because it added no answer the CLI did not already give.
3. **No client API.** Sundown never talks to an agent's API, reads its auth,
   or drives its UI. It reads the process table, config files on disk, and
   transcripts the client already wrote.
4. **No per-server cost claim from one machine.** The standing charge belongs
   to the whole connected set. A single machine can measure the total exactly
   and cannot split it. Splitting is a job for many machines with differing
   sets, which is the index, not the CLI.
5. **No telemetry, no accounts, no config file.**

## How it can fail

Two failure modes matter and they are not symmetric.

A **miss** is a server Sundown could have flagged and did not. The user keeps
paying. Annoying, recoverable, invisible.

A **wrong accusation** is Sundown telling the user to disconnect something
they depend on. They disconnect it, something breaks, and they stop trusting
the tool. There is no recovery from that.

Every ambiguous case resolves toward the miss. That is stated in the report
itself, in the last line of `--idle`, because a user who does not know the
tool abstains cannot read its silence correctly.

## Kill criteria

Recorded in `strategy/` and unchanged: if developers running many MCP servers
do not report context pressure as a felt problem, the premise fails and no
amount of measurement accuracy rescues it. That test is still unrun.
