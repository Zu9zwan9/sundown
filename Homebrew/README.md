# Publishing the Homebrew tap

Why this exists: the closest competitor installs with `npx zclean`. Until
Sundown installs in one command, none of its differentiators get a hearing.
This was the highest-leverage recommendation in `strategy/positioning-doc.md`.

## One-time setup

**1. Create the tap repository.** Homebrew requires the `homebrew-` prefix;
users never type it.

```bash
gh repo create Zu9zwan9/homebrew-sundown --public \
  --description "Homebrew tap for Sundown"
```

**2. Tag a release in this repo.**

```bash
git tag v0.1.0 && git push origin v0.1.0
```

**3. Get the tarball checksum.**

```bash
curl -sL https://github.com/Zu9zwan9/sundown/archive/refs/tags/v0.1.0.tar.gz \
  | shasum -a 256
```

**4. Fill in the formula.** Copy `sundown.rb` into the tap under `Formula/`
and add the stable pair above `head` — the in-tree formula ships head-only
because there is nothing to checksum until step 2 has run:

```ruby
url "https://github.com/Zu9zwan9/sundown/archive/refs/tags/v0.1.0.tar.gz"
sha256 "<the value from step 3>"
```

```bash
mkdir -p ../homebrew-sundown/Formula
cp sundown.rb ../homebrew-sundown/Formula/sundown.rb
```

**5. Test locally before pushing.**

```bash
brew install --build-from-source ../homebrew-sundown/Formula/sundown.rb
brew test sundown
brew audit --strict --new ../homebrew-sundown/Formula/sundown.rb
```

`brew audit --new` is the one that catches what reviewers would.

## What users then run

```bash
brew tap Zu9zwan9/sundown
brew install sundown
sundown --dry-run
```

Or in one line: `brew install Zu9zwan9/sundown/sundown`.

## Releasing an update

```bash
git tag v0.2.0 && git push origin v0.2.0
# recompute the sha256, bump url + sha256 in the tap's Formula/sundown.rb
```

Worth automating with a release workflow once there's a second version;
premature before that.

## What is deliberately not here

**The menu bar app.** A `.app` needs Developer ID signing and notarisation, or
Gatekeeper blocks it and the first-run experience is a scary dialog. That
belongs in a GitHub release with a notarised, stapled bundle — a separate job
requiring a paid Apple Developer account. `Scripts/bundle.sh` currently
ad-hoc signs, which is fine locally and not fine for distribution.

**A cask.** Only worth adding once the app is notarised.

**Auto-update.** No.
