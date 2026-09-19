# Changelog

## 0.2.1 — 2026-09-18

Release plumbing only. No behaviour changed.

The release workflow read `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD` and
`KEYCHAIN_PASSWORD`; the repository holds those values under `MACOS_CERT_P12`,
`MACOS_CERT_PASSWORD` and `MACOS_KEYCHAIN_PASSWORD`. Renaming three references
beats re-pasting a certificate.

Its header also still listed `APPLE_ID`, `APPLE_TEAM_ID` and
`APPLE_APP_PASSWORD` as required. Nothing has read them since the menu bar app
was removed and notarisation went with it.

`SIGN_IDENTITY` now defaults to the certificate's common name, which is public
and printed in every signed binary, so it needs no secret. It is quoted,
because that name contains a colon followed by a space and unquoted YAML reads
that as a mapping. GitHub could not parse the file at all and registered the
workflow under its own path instead of its name, which is why dispatching it
reported a missing trigger.

0.2.0 shipped unsigned through Homebrew, which builds from source and does not
care. This is the first tag that produces a signed tarball.

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
