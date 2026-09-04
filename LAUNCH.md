# Launch posts

Drafted from `strategy/positioning-statement.md`. The rules underneath every
one of these: lead with a **count**, name the **crash path**, say **every
tool**, never say "agent ops", never promise what the tool doesn't do.

A note on channel fit before you post anything: **Instagram and Threads are
the wrong rooms for this.** A macOS CLI for developers running MCP servers has
no visual hook and no audience there, and posting into silence costs more
credibility than it buys reach. Drafts are included because you asked, but I'd
skip both. Hacker News and GitHub are where this lives; LinkedIn and X are
worth it.

---

## Hacker News — the one that matters

**Title**

```
Show HN: Sundown – find the AI agent servers still running on your Mac
```

**First comment** (post immediately after submitting)

> I kept finding dozens of `node` processes I never launched. They're MCP
> servers — the background processes Claude Code, Cursor, Codex and friends
> spawn for tools. When a session ends cleanly most of them shut down. When it
> crashes, or you force-quit, or you just close the terminal, they don't: they
> get reparented to launchd and run until you reboot.
>
> The bug is open upstream in every vendor's tracker — Claude Code #1935 has
> been open 14 months. But the fixes being discussed are all `close()`-based,
> and a close handler can't run in a process that was killed. That path stays
> broken no matter who ships what.
>
> Sundown reads your MCP config *and* the process table, so it can name each
> leftover the way you named it (`filesystem`, and the folder it's serving)
> rather than showing you `node` forty times. It covers every agent tool on
> the machine, not one vendor's children. It won't touch a process whose
> session is still alive — with one exception, which took me a while to get
> right: if the same server is running six times, the older five aren't in use
> by anyone, and those it will take.
>
> Swift, no dependencies, nothing leaves your machine. `brew install`. MIT.
>
> The part I'd most like feedback on is the safety model — it's the whole
> product and there's no undo.

Post Tuesday–Thursday, 8–10am ET. Answer every comment for the first two
hours; that matters more than the title.

---

## LinkedIn

> Last week I found 1,706 background processes on a developer's Mac. None of
> them had been launched on purpose.
>
> They were MCP servers — the helpers that AI coding tools spawn to give a
> model access to your files, your repo, your database. They're supposed to
> shut down when a session ends. They usually do, if the session ends
> politely.
>
> Sessions rarely end politely. You force-quit. The terminal closes. Something
> crashes. The cleanup code lives inside the process that just died, so it
> never runs, and the servers get adopted by the operating system and keep
> going. One developer measured 14 GB.
>
> Every vendor has this open in their tracker. The oldest report is 14 months
> old. And the fixes under discussion can't reach the crash path, because a
> shutdown handler can't run in a process that was killed.
>
> So I built the thing that runs outside all of it. Sundown reads the config
> you wrote and the process table your machine keeps, matches them up, and
> ends what's left over — across every tool, not one vendor's.
>
> It's free, MIT, and nothing leaves your machine. Not because that's generous
> — because a tool with permission to kill your processes has to be
> auditable, and trust is the only feature that matters in that category.
>
> github.com/Zu9zwan9/sundown

---

## X / Twitter

**Thread**

> 1/ Found 1,706 background processes on a dev machine last week. None
> launched on purpose. ~14GB of RAM.
>
> They were MCP servers left behind by AI coding sessions. Here's why this
> keeps happening and why the fixes being discussed won't fix it 🧵

> 2/ MCP servers are child processes. Your agent spawns them for filesystem
> access, GitHub, Postgres, whatever.
>
> Session ends cleanly → they shut down. Usually.

> 3/ Session ends *uncleanly* — crash, force-quit, closed terminal — and the
> cleanup code never runs, because it lives inside the process that just died.
>
> The servers get reparented to launchd. They run until you reboot.

> 4/ This is open in every vendor's tracker. Claude Code #1935: 14 months.
> Codex, Cursor, Copilot CLI, Antigravity all have their own version.

> 5/ The proposed fixes are `close()` handlers. A close handler can't run in a
> process that was `kill -9`'d.
>
> That path stays broken no matter who ships what.

> 6/ So: Sundown. Reads your MCP config AND the process table, matches them,
> names each leftover the way you named it. Every tool, not one vendor's.
>
> Won't touch a live session. `brew install`. MIT.
>
> github.com/Zu9zwan9/sundown

**Standalone**

> Your AI coding tools left 14GB of background servers running.
>
> They shut down when a session ends politely. Sessions rarely end politely.
>
> `brew install sundown`

---

## Instagram / Threads — drafts, but see the note above

**Threads**

> Found 1,706 processes running on a laptop that nobody started.
>
> They were left behind by AI coding tools — the background helpers that are
> meant to shut down when you're done. They shut down if you quit properly.
> Nobody quits properly.
>
> Built a small free thing that finds them: github.com/Zu9zwan9/sundown

**Instagram** — needs a visual. The only one that would work is a screen
recording: Activity Monitor showing 40 identical `node` rows, cut to the
Sundown panel naming each one, cut to one click and the list emptying. Without
that footage there is no post worth making here.

---

## README badges

```markdown
![MIT](https://img.shields.io/badge/license-MIT-black?style=flat-square)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?style=flat-square)
![No telemetry](https://img.shields.io/badge/telemetry-none-black?style=flat-square)
```

That third badge is the positioning in a badge. Keep it.

---

## What not to say

| Don't | Why |
|---|---|
| "AgentOps for your Mac" | Real 2026 category meaning production observability. The words fit, the expectations don't. |
| "MCP orphan cleaner" | One Claude Code patch from meaningless. Lead with the crash path. |
| "Speed up your Mac" | Cleaner-adjacent, and the category is full of scams. |
| "AI-powered" | It is a process table reader. Nothing is inferred. |
| Any specific saving as a promise | 14 GB was one person's machine. Cite it as a report, never as a claim about the reader's. |
