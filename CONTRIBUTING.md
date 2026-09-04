# Contributing

Sundown sends signals to other people's processes. That single fact sets the
bar for everything below.

## Build and test

```bash
swift build
swift test
./Scripts/bundle.sh    # → build/Sundown.app and build/sundown
```

No Xcode project, no dependencies, no code generation. macOS 14+ and a Swift 6
toolchain is the whole requirement.

## The one rule that matters

**Every path to a signal goes through `Safety.swift`.** If you are adding a way
to terminate something, it calls `Safety.verdict(for:)` first, or the pull
request is wrong regardless of how good the rest of it is.

The refusals in that file are not a checklist someone assembled — each one is
a class of process that would break a machine if signalled. Adding a target
type means adding the refusal that keeps its neighbours safe, and a test that
proves it.

## What good looks like here

- **A test for the refusal, not just the feature.** `SafetyTests` should fail
  loudly if a change makes something newly killable.
- **Nothing invented.** `ContextCost` publishes a placeholder token figure and
  says so in the code. That honesty is a feature; keep it.
- **Prefer the smallest change that works.** No new dependency, no new
  abstraction layer, no configuration option, unless the alternative is
  materially worse. The codebase is meant to be readable in one sitting.
- **Comments explain why, never what.** If a line needs a comment to say what
  it does, rename something instead.

## Style

Run the formatter before you push:

```bash
swift format --in-place --recursive Sources Tests
```

CI runs exactly that and fails if it changes anything, so the fix for a red
formatting check is always the line above. The formatter ships with the
toolchain — nothing to install, nothing to pin.

The config enables formatting rules only. Naming, documentation comments, and
API shape are review matters, not linter matters.

## Porting to another platform

`SessionKit` imports no AppKit and no SwiftUI. The porting seam is the
`ProcessSource` protocol — implement it for Linux `/proc` or the Windows
toolhelp API and the policy, classifier, registry, and reaper come along
unchanged. That was the point of the split.

Please open an issue before starting one, so two people don't write the same
`/proc` reader.

## Releasing

Maintainers only:

```bash
./Scripts/bump-version.sh 0.2.0
git commit -am "Version 0.2.0" && git tag v0.2.0 && git push --tags
```

The tag triggers `.github/workflows/release.yml`, which signs, notarises, and
opens a draft release. See [`DISTRIBUTION.md`](DISTRIBUTION.md) for the
one-time certificate setup.

## Reporting a safety bug

If you find a way to make Sundown signal something it should not — a system
daemon, another user's process, a GUI application — that is the highest
priority issue this project can receive. Open it with the command line of the
process that was wrongly selected and the phase you were in. No need to be
polite about it.
