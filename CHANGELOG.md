# Changelog

## 0.2.0 — 2026-09-18

Sundown could see servers running and could not name them, so it declined to
judge them. On the author's machine that was six of seventeen processes and
roughly 16,000 tokens of standing charge it never mentioned.

**Plugin servers are now found.** Two gaps, both silent:

- `~/.claude/plugins/synced/` was never scanned. Only `installed_plugins.json`
  was, which lists marketplace installs and none of the account-synced
  plugins.
- Synced plugins write `mcp.json`. The reader looked only for `.mcp.json`.

**Wrapper chains inherit their launcher's declaration.** `npx -y @scope/pkg`
runs as `npm exec`, which spawns `node`, which spawns two more binaries, none
carrying the declared token. The nearest declared ancestor now names them. The
walk stops at the first client, so a server never inherits from a sibling, and
inheritance names an existing row rather than creating one.

**"Declared but not running" lists only servers you have actually called.**
Reading the plugin directory turned that section from eight lines into
twenty-three, most of them plugins installed and never opened. A server you
have never called and that is not running is not an absence.

Measured on one machine: unattributed processes 6 to 3, never-called servers
found 2 to 4, standing charge identified as idle 13,460 to 32,900 tokens of
74,031.

**Fixed:** `Scripts/bump-version.sh` wrote to the menu bar app's `Info.plist`,
deleted when that app was removed. A bump wrote `VERSION`, failed, and left
`main.swift` behind — the version split the script exists to prevent.

**Added:** `PRD.md` and `SDD.md`. Requirements, non-goals and the invariants
that must not be broken casually, including why a borrowed declaration is kept
out of supersede detection.

## 0.1.0

First release.
