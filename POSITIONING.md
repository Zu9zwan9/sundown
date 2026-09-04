# Sundown — competitors, proposition, activation

Companion to `MARKET.md`. That document asks whether this is a business. This
one asks what the product actually is.

## Three adjacent categories, and the hole between them

The competitive set isn't one shelf. It's three, and each is blind to
something the others see.

### 1. Port and process killers

[PortKiller](https://github.com/gupsammy/PortKiller/) ·
[macos-port-killer](https://github.com/shaneholloman/macos-port-killer) ·
[Node Killer](https://github.com/adolfoflores/node-killer) ·
[Port Kill](https://alternativeto.net/software/port-kill/about)

Organised around a port number. PortKiller is the strongest — it separates
processes, Docker containers, and Homebrew services, and it's free and open
source.

**What they can't see:** MCP servers communicate over stdio. They hold no
port. A port-centric tool is structurally blind to the majority of what
Sundown exists to find. This isn't a quality gap that a better port killer
closes; it's a category boundary.

### 2. Resource monitors

[RAMBar](https://maxghenis.com/blog/rambar/) · Activity Monitor · Sensei

RAMBar is the closest thing that exists — it already tracks memory across
Claude Code sessions specifically, so someone else read the same signal.

**What they can't do:** they report. Seeing that `node` is holding 340 MB
doesn't tell you whether ending it costs you an hour of work. Monitors leave
the risky judgement entirely with the user, which is why people watch them
and then don't act.

### 3. MCP configuration managers

[MCP Manager for Claude Desktop](https://mcp-manager.zue.ai/) ·
[MCP-Manager-GUI](https://github.com/gabrielbacha/MCP-Manager-GUI) ·
[mcp-manager](https://github.com/amxv/mcp-manager) ·
[MediaPublishing/mcp-manager](https://github.com/MediaPublishing/mcp-manager)

A real and growing category: toggle servers on and off, auto-discover
existing configurations, import and export, back up and restore.

**What they can't see:** they operate on `claude_desktop_config.json`. They
know what you *declared*. They never look at the process table, so they cannot
tell you that a server you disabled three weeks ago is still running from a
session you've forgotten. Config is a statement of intent. It is not a
statement of fact.

### The hole

| | Knows declared names | Sees running processes | Ends things safely |
| --- | :---: | :---: | :---: |
| Port killers | ✗ | partial (ports only) | ✓ |
| Resource monitors | ✗ | ✓ | ✗ |
| MCP config managers | ✓ | ✗ | ✗ |
| **Sundown** | **✓** | **✓** | **✓** |

Nobody joins the two halves. That join is the product.

## The proposition

> **Sundown is the only tool that sees both what your config declared and
> what is actually still running — and can tell the difference between your
> work and your leftovers.**

Everything defensible follows from the join:

**Certainty instead of heuristics.** Reading `claude_desktop_config.json`,
`~/.claude.json`, `.mcp.json`, and `~/.cursor/mcp.json` means a running
process can be matched to a declaration. `filesystem` stops being a guess
parsed out of a 140-character node invocation and becomes the literal key you
typed. A config manager has this name and no process. A port killer has this
process and no name.

**Evidence a user can check.** "Declared in Claude Desktop · running since
09:14" is a claim you can verify against your own file. "node, 340 MB" is a
claim you can only accept.

**Safety that reads as competence.** Refusing to touch app bundles, shells,
and container daemons is not a feature list — it's the reason someone presses
a button that has no undo. This is the least glamorous work in the project and
the most load-bearing.

**The one-sentence version for a README:** *Your agent sessions leave servers
running. Sundown finds them by name and ends them.*

## The aha moment

The aha is not "this app kills processes." It's a specific sentence a user
says out loud:

> **"That's been running since this morning and I had no idea."**

Two things have to be true in the same glance for that sentence to happen.

**Recognition — the names have to be theirs.** `filesystem`, `github`,
`postgres` are things the user typed into a config file. `node
/Users/…/dist/index.js` is anonymous. Anonymous things don't produce guilt or
relief; they produce shrugging. This is why the config join matters more for
activation than for correctness.

**Duration — the number has to be embarrassing.** "14 items" is a quantity.
"Oldest: 6h 12m" is a story about the last six hours of not knowing.
Duration is the emotional payload; count is just the receipt.

### What currently blocks it

Three things in the build as it stands work against the aha:

1. **The header leads with count, not age.** `14 items from this session` is
   the receipt, not the story.
2. **Names are heuristic.** `Classifier.displayName` does string surgery on a
   path. It gets `filesystem` right often — but "often" is the wrong bar for
   the one thing that has to feel personal.
3. **A clean first run is an anticlimax.** "Your session is clean" on first
   launch is the worst possible first impression: the app has proven nothing
   and taught nothing. Right now that's a coin flip on install.

### Changes that engineer it

| Change | Effect |
| --- | --- |
| Header reads `14 items · oldest 6h 12m` | Duration becomes the headline |
| Match processes to config declarations | Names become recognisably the user's own |
| Row evidence reads `Declared in Claude Desktop` | The claim is checkable against a file they own |
| Clean first run explains what it watches for | Never a blank first impression |
| Sort orphans first, oldest first *within* kind | The most damning row is at the top |

The first four are small. The config match is the one with real work in it,
and it happens to be the same work that produces the proposition — which is
usually a sign the shape is right.

### The second moment, for retention

Aha gets the install. What gets the habit is the closing beat: pressing **End
Session** and watching a full panel become one quiet line — *Ended 14 items ·
1.05 GB reclaimed*. That is the only moment in the app that should feel good,
which is why it's the only place with any bounce in the animation and the only
one with a symbol effect. Every other transition is critically damped on
purpose.

Do not add a lifetime counter — *"42 GB reclaimed across 118 sessions"* — to
chase this. It converts a clean utility into a scoreboard, and it rewards the
app for a problem existing rather than for solving it.
