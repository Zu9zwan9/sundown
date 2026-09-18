# Sundown — design

`PRD.md` says what it must do. This says how, and which parts must not be
changed casually.

## The one idea

Three sources disagree, and the disagreement is the product:

```
  process table          what is actually running
  MCP client config      what the user declared
  session transcripts    what was actually called
```

Every other tool in this space reads one of them. A port killer reads the
process table and cannot tell a server from a dev server. A config manager
reads the config and cannot tell you what it costs. Nobody reads transcripts.

The join key is **the declaration**, not the process name. The key the user
typed in their config is also the key the client sanitises into the transcript
tool id, so it is the only identifier that reaches all three sources. A row
Sundown cannot key this way is a row it refuses to judge, which is why the
matching code is the part most worth being careful with.

## Module map

**Reading the world**

| | |
|---|---|
| `DarwinProcessSource` | the live process table via `libproc`. The only platform-specific file. |
| `MCPRegistry` | declarations from every client config on disk, including plugin manifests. |
| `TranscriptMetrics` | token usage and call counts, parsed from session transcripts. |
| `PortScanner`, `ContainerScanner` | listening ports, and containers that look like this session's. |

**Deciding**

| | |
|---|---|
| `Classifier` | what a process *is*, from argv alone. |
| `Provider` | which client a process belongs to, and which clients exist. |
| `SessionScanner` | assembles one view: classify, name, own, supersede, collect subtrees. |
| `ServerSet` | groups processes by declaration into one record per declared server. |
| `Safety`, `SessionPolicy` | what may be ended, and when. |

**Reporting and acting**

| | |
|---|---|
| `IdleServerReport` | servers paid for and never called, plus every abstention. |
| `ContextSnapshot` | before/after markers for `--snapshot` / `--compare`. |
| `ContributionDocument` | what this machine may honestly say in public. |
| `Reaper` | ends things, term before kill. |
| `SelfTest` | the whole join, checked on the machine it runs on. |

## The matching rules, in order

1. **Direct declaration match.** The process command line contains a
   declaration's fingerprint. The fingerprint is the most package-like token
   in the declared args, because `@modelcontextprotocol/server-filesystem`
   identifies a server while `/Users/me/Documents` is an argument to one.
   Longest fingerprint wins, so a specific declaration beats a generic prefix.

2. **Inherited declaration.** No direct match, but an ancestor has one.
   `npx -y @gitkraken/gk mcp` becomes `npm exec ...`, which spawns `node`,
   which spawns two more binaries, none of which carry the declared token. The
   walk stops at the first identified client, so a server never inherits from
   a sibling higher up the same tree.

3. **Classifier heuristic.** Neither of the above, but the command line looks
   like an MCP server. Named, never joined, never counted as idle.

4. **Nothing.** Reported as unjudged with the reason.

Inheritance names a row; it never creates one. A process the classifier did
not already consider a server does not become one by having a declared
ancestor, so a server's transient `git` child is not counted as a copy of it.

## Invariants

Breaking any of these is a bug regardless of what the tests say.

**A borrowed declaration is not an instance.** Supersede detection keys on the
declaration when there is one, so four links of a wrapper chain sharing one
inherited declaration would read as four competing copies and three would be
offered for termination. Borrowed declarations are excluded from instance
identity and keep the argv-based key.

**Nothing with a live identified owner is ever signalled.** The check starts
at the parent, never the process itself, because a running agent CLI is the
session rather than something owned by one.

**A report path never becomes an action path.** `--idle`, `--snapshot`,
`--compare` and `--contribute` set dry-run, and `--yes` cannot lift it. CI
asserts the binary refuses to act on a non-TTY without `--yes`.

**No sockets.** `--contribute` prints and exits. The published document
carries a measured total and an exact server set, never a per-server split,
because one machine cannot honestly produce one.

**The transcript id is the join.** Getting a declaration's name wrong is not a
display bug. `plugin:<plugin>:<server>` is what the client uses and what
sanitises into the tool id; a name from the wrong directory silently produces
a server that appears never to have been called.

## Known limits

1. **Plugins hosted outside `~/.claude/plugins`.** Servers launched from
   `/var/folders/.../claude-hostloop-plugins/` are declared nowhere Sundown can
   read. Currently three processes on the author's machine. Reported unjudged.
2. **Claude Desktop transcripts are not read**, so its servers are never
   judged idle. A zero there would be an artefact of where history lives.
3. **Per-server cost is a share.** The standing charge is a property of the
   whole set. Recovering per-server figures needs many machines with differing
   sets, solved as a system rather than divided.
4. **Session liveness is not modelled.** Transcripts carry no session-end
   record, so "this session finished" is not knowable from disk. Only "last
   activity at T" is. See `strategy/validation/f7-scope-check-2026-09-18.md`.
5. **macOS only.** `DarwinProcessSource` is the single porting seam.

## Testing approach

Tests cover the two things that can do damage: what Sundown decides to call a
target, and what it refuses to touch. Logic that could produce a wrong
accusation ships with a test that fails when it does. Fixtures come from real
process chains observed on real machines rather than invented ones, because
the bugs found so far have all been shapes nobody would have invented.
