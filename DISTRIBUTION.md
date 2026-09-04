# Distribution

## The Mac App Store is not available to this app

Not "difficult" — structurally closed. Worth knowing before anyone opens App
Store Connect.

Mac App Store apps must adopt the **App Sandbox** entitlement. A sandboxed
process cannot:

- send signals to processes outside its own sandbox, which is the entire
  product — `kill(pid, SIGTERM)` is denied;
- read another process's arguments via `KERN_PROCARGS2`, which is how every
  server gets its name;
- read `~/Library/Application Support/Claude/claude_desktop_config.json`
  without a user-granted security-scoped bookmark, which defeats the config
  join;
- spawn `lsof` or `docker`.

There is no entitlement that restores process control to a sandboxed app.
Apple does not grant temporary exceptions for it. Utilities that manage other
processes — including every competitor found in research — ship outside the
store for exactly this reason.

> Verify against the current App Review Guidelines before quoting this to
> anyone. The reasoning is structural and unlikely to have changed, but it is
> reasoning rather than a citation.

**So: direct distribution only.** That is also the right answer commercially.
The audience installs developer tools from a terminal, and the tap is a better
front door than a store listing.

---

## What direct distribution requires

Three things, in order of how much they cost you.

### 1. Homebrew tap — the CLI

Free, no Apple account. This is the real distribution channel. See
[`Homebrew/README.md`](Homebrew/README.md).

```bash
brew install Zu9zwan9/sundown/sundown
```

### 2. npm — the try-it-once channel

The name `sundown` on npm belongs to
[Ionică Bizău's sunrise/sunset calculator](https://www.npmjs.com/package/sundown),
published since February 2018 and still maintained (2.0.2, February 2025, MIT).
`npx sundown` fetches that, not this. Checked before choosing, along with the
alternatives:

| name | npm | github |
| --- | --- | --- |
| `sundown` | taken since 2018 | `github.com/sundown` taken |
| **`sundown-cli`** | **free** | `github.com/sundown-cli` free |
| `sundowncli` | free | free |
| `sundown-mcp` | free | — |
| `@sundown/*` | scope unverifiable from here | — |

**`sundown-cli`**, unscoped. A scope would have been the tidier answer if the
`@sundown` org were confirmed free, and it could not be confirmed — npm's org
lookup is behind bot protection, and claiming a scope you cannot verify is how
you find out at publish time. The unscoped name is verified free by the
registry API, reads better in the one place it appears (`npx sundown-cli`), and
leaves the command itself as `sundown`.

Homebrew is unaffected: in a personal tap the name is free, so
`brew install Zu9zwan9/sundown/sundown` stands.

The package is a fetcher, not a bundle. `bin/sundown.js` downloads the release
asset for the current arch on **first run** — no postinstall, because a
postinstall that downloads a binary is the thing people rightly disable — and
verifies it against a checksum recorded in `package.json` before executing it.
A build with no recorded checksum refuses to run anything and points at
Homebrew.

That makes the asset name a contract:

```
sundown-macos-arm64.tar.gz     containing a single executable named `sundown`
sundown-macos-x64.tar.gz
```

`Scripts/release-cli.sh` builds one, signs it if `SIGN_IDENTITY` is set, and
writes its checksum into `package.json`. Run it on each architecture you intend
to publish for.

### 3. Notarised app — the on-ramp

Needs a paid Apple Developer account for a **Developer ID Application**
certificate. Without it, Gatekeeper shows *"Sundown cannot be opened because
the developer cannot be verified"* — a terrible first impression for software
asking to end your processes.

`Scripts/release.sh` does the whole thing. Two one-time steps first.

**a. Get the certificate.** At developer.apple.com → Certificates → **+** →
**Developer ID Application**. Download, double-click to install. Verify:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

The Team ID is the 10-character code in parentheses at the end. An *Apple
Development* certificate is not enough — notarisation requires Developer ID
specifically, and this is the most common thing to get wrong.

**b. Store notary credentials in the keychain.** Generate an app-specific
password at appleid.apple.com → Sign-In and Security → App-Specific Passwords.
Your normal Apple password will not work.

```bash
xcrun notarytool store-credentials "sundown-notary" \
  --apple-id "you@example.com" \
  --team-id "KSDM65552F" \
  --password "abcd-efgh-ijkl-mnop"
```

Keychain, not a file — nothing about your Apple account should ever land in
this repo.

**Then, per release:**

```bash
./Scripts/release.sh          # → build/Sundown.zip
./Scripts/release.sh --dmg    # → build/Sundown.dmg, also notarised
```

It runs the tests first and refuses to ship if they fail, checks both
credentials before building so a missing one costs a second rather than a full
release, signs with the hardened runtime and a secure timestamp, notarises,
staples, and finishes with `spctl --assess` — which is what Gatekeeper will
actually say on a machine that has never seen the app.

**Entitlements: none.** `Scripts/Sundown.entitlements` is deliberately empty
and documents what is absent and why. Under the hardened runtime, Sundown
still reads same-user process arguments, signals them, and spawns `lsof` and
`docker` — none of that is entitlement-gated. An empty file is the smallest
possible claim on the user's machine, which is the point.

### 4. Homebrew cask — optional

Only once the app is notarised. A cask pointing at an unsigned build just
moves the Gatekeeper dialog somewhere less expected.

---

## Permissions the app will ask for

Sundown reads other processes' arguments and sends them signals. On recent
macOS that can prompt, and it is better to explain it before the dialog than
after.

| Capability | Needed for | Prompt |
|---|---|---|
| Reading other processes' argv | Naming servers, matching config | None for same-user processes |
| Sending SIGTERM/SIGKILL | The entire product | None for same-user processes |
| Running `lsof` | Port detection | None |
| Running `docker` | Container detection | None |
| Login item (`SMAppService`) | Open at login | System Settings toggle |

Sundown deliberately never requests Full Disk Access, Accessibility, or
Automation. If a build ever asks for one of those, something is wrong.

---

## Releasing from CI

`.github/workflows/release.yml` runs the whole thing on a pushed tag. Six
repository secrets, set once:

| Secret | Where it comes from |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | `base64 -i DeveloperID.p12 \| pbcopy` |
| `P12_PASSWORD` | the password you set when exporting the .p12 |
| `KEYCHAIN_PASSWORD` | any random string — a throwaway keychain uses it |
| `APPLE_ID` | your Apple ID email |
| `APPLE_TEAM_ID` | the 10-character Team ID |
| `APPLE_APP_PASSWORD` | app-specific password from appleid.apple.com |

Export the `.p12` from Keychain Access → your Developer ID Application
identity → right-click → Export. Include the private key.

**No provisioning profile.** Those are for App Store and device builds;
Developer ID direct distribution doesn't use one. Adding it to the recipe is a
common way to lose an afternoon.

Then a release is two commands:

```bash
./Scripts/bump-version.sh 0.2.0
git commit -am "Version 0.2.0" && git tag v0.2.0 && git push --tags
```

The workflow tests, signs, notarises, staples, builds the DMG, prints the
tarball sha256 for the tap formula, and opens a **draft** release. Draft
deliberately — see the checklist below for the one thing CI cannot do.

---

## Release checklist

Automated (CI fails the release if any of these fail):

- [x] `swift test` green
- [x] Version consistent across `VERSION`, `Info.plist`, `main.swift`
- [x] No `get-task-allow` in the entitlements or the signed bundle
- [x] Icon regenerated — `bundle.sh` does it every build
- [x] Signed, notarised, stapled, `spctl --assess` clean
- [x] Tarball sha256 printed in the workflow log

Still yours:

- [ ] `sundown --dry-run` on a machine with real leftovers
- [ ] `sundown --phase during --dry-run` with a live session open — must not
      select anything belonging to it
- [ ] **Opened the artefact on a Mac that has never seen the app.** The build
      machine's keychain makes Gatekeeper lenient, so passing there proves
      less than it looks. This is the only check that matters, and it is the
      reason the release is created as a draft.
- [ ] sha256 from the workflow log into the tap formula
- [ ] `brew audit --strict --new` clean
- [ ] Release notes name what changed in the safety rules — that is the part
      people need to re-read
- [ ] Publish the draft

---

## Deliberately not doing

**Auto-update.** A tool with permission to kill processes should not be able
to silently replace itself. `brew upgrade` is the update mechanism.

**Telemetry.** Not even anonymous counts. The positioning rests on it, and
"we only collect anonymous usage data" is exactly the sentence that loses this
category's trust.

**A signed installer package.** `.pkg` installers run scripts as root. For a
process-killing utility that is the wrong shape entirely.
