# Building

Builds clean on macOS 14+ with Xcode 15+. 40 tests green as of the last run.

I can't compile here — no macOS SDK, and installing a Swift toolchain in my
Linux sandbox measured out at roughly thirty minutes of downloading to
type-check about 60% of the project, against twenty seconds on your machine.
So the loop is: you run it, I fix what comes back.

## Run

```bash
cd Sundown
swift build 2>&1 | head -60
```

The CLI is the faster thing to sanity-check, because it needs no bundle:

```bash
swift run sundown --dry-run
swift run sundown --list-providers
```

Then, if that's clean:

```bash
swift test 2>&1 | tail -40
./Scripts/bundle.sh && open build/Sundown.app
```

Requires macOS 14+ and Xcode 15+ (`xcode-select --install` if `swift` isn't
found).

## Still unverified

The CLI and `SessionKit` are exercised. The SwiftUI layer has only ever been
compiled, never looked at, so these are unproven rather than suspect:

1. **The panel's measured list height.** The bug that started this — a
   `ScrollView` starving to a sliver inside a size-to-fit `VStack` — is fixed
   by measuring content and giving it a real frame. Whether the numbers feel
   right at 14 rows is a thing only you can see.
2. **`Duration.components` in `SessionScanner.cpuRates`.** Compiles and the
   shape is right, but a scaling error here would report plausible nonsense.
   Worth eyeballing one `cpuPercent` against Activity Monitor.
3. **Strict concurrency.** `onPreferenceChange` and the `.task` loops mutate
   `@State`. Fine in Swift 5 language mode, noisy if you move to Swift 6.

## Fastest useful reply

Just the first 20 lines of `swift build` output. Errors cascade, so the first
few are almost always the only real ones.

## Verifying it actually works, once it builds

Compiling proves nothing about behaviour. Three checks worth a minute each:

**It sees your servers by name.** Open the panel with Claude Desktop running.
Rows should read `filesystem`, `github` — the keys from
`claude_desktop_config.json` — and hovering one should say *Declared in Claude
Desktop*. If they read like file paths instead, the config join isn't matching
and `MCPRegistry.fingerprint` needs looking at.

**It refuses what it should.** Claude Desktop, your terminal, and your editor
must never appear in the list. If any of them does, stop and tell me — that's
the one class of bug that costs you real work.

**It's honest about ending.** Pick one row, note the pid, press End Session,
then `ps -p <pid>` in a terminal. Gone means gone.

**It won't touch a live session.** With Claude Desktop open, its servers
should appear unchecked, saying *In use by Claude Desktop*. Switch to Triage
in the ⋯ menu and the list should shrink to orphans and duplicates only. If a
live-owned row ever arrives pre-checked, that's the one bug worth stopping
for — `SessionPolicyTests.testLiveOwnedIsNeverPreselectedInAnyPhase` covers
it, so a failure there is the fastest signal.

**The CLI agrees with the GUI.** `sundown --dry-run` and the panel should
select the same rows. They share `SessionPolicy`, so a disagreement means one
of them is filtering somewhere it shouldn't.
