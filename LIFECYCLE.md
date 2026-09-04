# Shutting things down without a dashboard

Sundown never talks to an agent's API, reads its session state, or asks it for
permission. It works from the outside, on two things any process on your Mac
can see: **the process table** and **the config files you wrote yourself**.
That's the whole mechanism, and it's why it works identically for Claude Code,
Codex, Cursor, and anything that hasn't shipped yet.

The GUI is one way to drive it. The `sundown` binary is the other, and it's the
one you wire into a hook.

---

## The three moments

Cleaning up before you start, while you're working, and after you finish are
three different problems. Collapsing them into one "kill everything" button is
how a cleanup tool eats a live session and never gets opened again.

| Phase | When | What it touches | What it checks by default |
| --- | --- | --- | --- |
| `before` | Preflight, at session start | Everything | Everything without a live owner, **including** stray ports and idle containers |
| `during` | Mid-session triage | Orphans, duplicate servers, processes over 50% CPU | Orphans and duplicates only |
| `after` | Teardown, the default | Everything | Confidently-identified session processes without a live owner |

### The invariant that holds across all three

**Anything with a living, identified owner is never checked by default.**

If Sundown can walk a process's ancestry up to a running Claude Desktop or
`claude` CLI, that process belongs to a session somebody is using. It stays
visible, stays unchecked, and says *In use by Claude Code* when you hover it.
You can check it yourself. Sundown will not check it for you.

This is why `during` is usable at all. It's also why `after` won't quietly
break a Claude Desktop window you left open.

### Why `before` sweeps wider than `after`

At preflight, nothing running is yours — you haven't started. So `before`
also checks the uncertain matches: the Vite server on 5173, the container
that's been up since Tuesday.

At teardown you may well want that Postgres container to survive the end of
your workday, so `after` checks only what it's confident about.

### What `during` actually detects

Three things, and only three:

- **Orphans** — reparented to `launchd`. The client that spawned them quit and
  left them running. Unambiguous.
- **Superseded duplicates** — you have six `filesystem` servers because every
  session spawned a fresh one and none cleaned up. Only the newest is doing
  anything; the rest are checked for you.
- **Runaways** — sustained CPU above 50% of a core. Shown, **not** checked.
  Busy is not the same as abandoned, and this is the phase where being wrong
  costs the most.

Runaway detection needs two scans to difference, so the CLI takes an extra
second in `--phase during` and tells you if rates weren't available.

---

## Wiring it in

Install the binary first:

```bash
./Scripts/bundle.sh              # builds the app and the CLI
sudo cp build/sundown /usr/local/bin/
sundown --dry-run                # always start here
```

### As a Claude Code hook

Claude Code can run a command when a session ends. In `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionEnd": [
      {
        "hooks": [
          { "type": "command", "command": "sundown --phase after --yes --quiet" }
        ]
      }
    ]
  }
}
```

> Check the current hook schema against Claude Code's own documentation before
> pasting this — hook event names and nesting have changed between releases,
> and I'd rather you verify it than trust my recollection.

Note `--yes`. Without it, Sundown refuses to run non-interactively rather than
hanging on a prompt nobody will answer. That refusal is deliberate: a hook
that silently kills things is worse than a hook that doesn't run.

### As a shell trap

For a wrapper that cleans up whenever your agent exits, however it exits:

```bash
# ~/.zshrc
agent() {
  trap 'sundown --phase after --yes --quiet' EXIT INT TERM
  command claude "$@"
}
```

### As a periodic orphan sweep

Orphans are safe to end at any time by definition — their client is gone. A
launchd job can collect them every fifteen minutes without ever touching a
live session.

`~/Library/LaunchAgents/com.sundown.sweep.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.sundown.sweep</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/sundown</string>
        <string>--phase</string><string>during</string>
        <string>--yes</string>
        <string>--quiet</string>
    </array>
    <key>StartInterval</key><integer>900</integer>
    <key>RunAtLoad</key><false/>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.sundown.sweep.plist
```

`--phase during` is the right choice here, not `after`. A background job must
never end anything that a session is using, and `during` is the phase built to
that constraint.

### When nothing gets selected

Run `sundown` mid-session with your apps open and you'll see something like:

```
Teardown — Ends what your session started. Leaves long-lived services alone.

Claude Desktop
    filesystem              124 MB   6h 12m       In use by Claude Desktop — unchecked so a live session survives
    github                   86 MB   6h 12m       In use by Claude Desktop — unchecked so a live session survives
    postgres                 71 MB      6h        In use by Claude Desktop — unchecked so a live session survives
Unattributed
    node · :5173             98 MB      2h        Uncertain match — check it yourself if you mean it

Nothing selected.
  6 in use by a running session — quit the app, or --include-in-use to end them anyway.
  3 uncertain — --phase before also takes stray ports and idle containers.
```

That is the invariant working, not a failure. The list still prints in full,
every row says why it wasn't taken, and each hint names the flag that answers
it:

```bash
sundown --include-in-use -n     # look at what that would take, first
sundown --include-in-use -y     # then do it
sundown --phase before -n       # include the uncertain ones too
```

`--include-in-use` is the same override as ticking the boxes yourself in the
panel. It applies the phase's own rule with the ownership guard lifted, so it
can't select something the phase wouldn't have wanted anyway.

Running from a `SessionEnd` hook avoids the question entirely: by then the
owner is exiting, and the leftovers are genuinely leftovers.

### Scoped to one tool

```bash
sundown --provider claude-code --yes     # only Claude Code's leftovers
sundown --list-providers                 # the ids you can pass
```

Useful when you're done with one agent but still working in another.

### In CI

```bash
sundown --phase after --yes --json > cleanup.json
```

Exit `0` means everything ended or there was nothing to do; `1` means
something survived; `2` means you got the arguments wrong.

---

## The JSON contract

`--json` emits explicit DTOs rather than serialising internal types, so
refactors inside Sundown can't silently break your script.

```json
{
  "phase": "after",
  "dryRun": false,
  "scannedAt": "2026-08-14T09:14:22Z",
  "summary": {
    "found": 14, "selected": 6,
    "reclaimableBytes": 852000000,
    "cpuRatesAvailable": true
  },
  "items": [
    {
      "id": "pid-4821", "title": "filesystem", "kind": "mcpServer",
      "provider": "claude-desktop", "providerName": "Claude Desktop",
      "pid": 4821, "residentBytes": 130023424, "cpuPercent": 1.2,
      "ageSeconds": 22320,
      "orphaned": true, "superseded": false, "inUse": false,
      "selected": true,
      "reason": "Orphaned — its client quit and left it running",
      "evidence": "Declared in Claude Desktop · reparented to launchd"
    }
  ],
  "results": [
    { "id": "pid-4821", "title": "filesystem",
      "outcome": "exited", "detail": null, "reclaimedBytes": 130023424 }
  ]
}
```

`results` is `null` on a dry run, `[]` when there was nothing to do.
`cpuRatesAvailable: false` means runaway detection didn't run — treat every
`cpuPercent` in that response as unknown rather than as zero.

---

## Running it unattended, safely

Everything below is enforced in code, not documentation.

- **`SafetyGuard` is the only path to a signal.** There is no second way to
  send one. It refuses PIDs under 100, other users' processes, Sundown's own
  ancestry, anything inside a `.app`/`.appex`/`.xpc` bundle, anything under
  `/System` or `/usr/libexec`, shells, multiplexers, and container daemons.
- **Refusing the parent spares the children.** Verdicts are decided for a
  whole subtree before any signal is sent, so a refused target never loses its
  leaves.
- **`SIGTERM` first, always.** Three seconds by default, `--grace` to change
  it. `SIGKILL` only for what refuses to leave.
- **Containers stop through `docker stop`.** The daemon is never signalled.
- **Non-interactive without `--yes` is refused, not assumed.**

The one thing that isn't enforced in code: **run `--dry-run` before you put
any of this in a hook.** There's no undo, which is exactly why every row can
explain itself before you commit.

---

## What this deliberately does not do

- **No agent APIs.** Nothing here depends on a vendor exposing session state,
  which is why it works the same for all of them and won't break when one
  ships a new release.
- **No config editing.** Sundown reads your MCP declarations to identify
  processes. It never writes to them. Disabling a server is your client's job.
- **No persistent allow list.** Deliberately absent until the detection rules
  have been used against real machines for a while — a saved kill list is a
  saved liability.
- **No project-local `.mcp.json`.** We don't know which directories you've
  opened, and walking the disk to find out would be worse than the miss.
