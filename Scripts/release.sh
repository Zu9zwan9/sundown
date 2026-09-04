#!/usr/bin/env bash
# Build, sign, notarise, staple, verify. One command, because the failure mode
# of doing this by hand is discovering a missing flag after a five-minute
# round trip to Apple's notary service.
#
# One-time setup (stores an app-specific password in your keychain — never in
# this repo):
#
#   xcrun notarytool store-credentials "sundown-notary" \
#     --apple-id "you@example.com" --team-id "KSDM65552F" --password "abcd-efgh-ijkl-mnop"
#
# App-specific passwords come from appleid.apple.com → Sign-In and Security.
# Your normal Apple password will not work.
#
# Then:  ./Scripts/release.sh [--dmg]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Sundown.app"
PROFILE="${NOTARY_PROFILE:-sundown-notary}"
MAKE_DMG=false
[[ "${1:-}" == "--dmg" ]] && MAKE_DMG=true

fail() { echo "✗ $1" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────
# Check everything before building, so a missing credential costs a second
# rather than a full release build.

echo "▸ Preflight"

IDENTITY="$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" \
  | head -1 \
  | sed -E 's/.*"(Developer ID Application: .*)"/\1/')" || true

[[ -n "$IDENTITY" ]] || fail "No 'Developer ID Application' certificate in your keychain.
  Create one at developer.apple.com → Certificates, download it, double-click to install.
  Note: an 'Apple Development' cert is NOT enough — notarisation needs Developer ID."

echo "  identity: $IDENTITY"

# No --limit: it isn't a valid option in every notarytool version (Xcode 26
# rejects it), and a preflight that fails on a flag rather than on the thing it
# is checking is worse than no preflight. Output is discarded anyway.
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "Notary profile '$PROFILE' not found, or it can't reach Apple.
  Run:  xcrun notarytool store-credentials $PROFILE
  and leave the API-key path blank to authenticate with an Apple ID instead."

echo "  notary profile: $PROFILE"

# One version, three files. Cheap to check, annoying to discover afterwards.
"$ROOT/Scripts/bump-version.sh" --check || exit 1

# Apple rejects any notarisation carrying get-task-allow set true — it's the
# debug entitlement that lets a debugger attach, and Xcode adds it silently to
# Debug configurations. PlistBuddy rather than grep, so the long explanatory
# comment inside the entitlements file can name the key without tripping this.
if /usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" \
     "$ROOT/Scripts/Sundown.entitlements" >/dev/null 2>&1; then
  fail "com.apple.security.get-task-allow is set in Sundown.entitlements.
  Notarisation rejects it. Remove the key before releasing."
fi

# ── Build ────────────────────────────────────────────────────────────────────

echo "▸ Tests"
swift test --package-path "$ROOT" >/dev/null || fail "Tests failed. Not shipping."

echo "▸ Build"
CONFIG=release "$ROOT/Scripts/bundle.sh" >/dev/null
[[ -d "$APP" ]] || fail "No app at $APP"

# ── Sign ─────────────────────────────────────────────────────────────────────
# --options runtime  : hardened runtime, required for notarisation
# --timestamp        : secure timestamp, required for notarisation
# No --deep: it's discouraged and this bundle has no nested code to reach.

echo "▸ Sign"
codesign --force --options runtime --timestamp \
  --entitlements "$ROOT/Scripts/Sundown.entitlements" \
  --sign "$IDENTITY" "$APP"

codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

# Read back what actually got embedded rather than trusting what we passed in.
# The preflight check covers the source file; this covers the sign command
# itself pointing at the wrong file, which is the mistake that survives a
# careful look at the entitlements.
EMBEDDED="$(codesign -d --entitlements - "$APP" 2>&1)"
if grep -q "get-task-allow" <<< "$EMBEDDED"; then
  fail "The signed bundle carries com.apple.security.get-task-allow.
  Notarisation will reject it. Check --entitlements above points at
  Scripts/Sundown.entitlements and that CONFIG=release."
fi
echo "  entitlements: clean (no get-task-allow)"

# ── Notarise ─────────────────────────────────────────────────────────────────

echo "▸ Notarise (this takes a few minutes)"
ZIP="$ROOT/build/Sundown-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait \
  || fail "Notarisation failed. See the log:
  xcrun notarytool log <submission-id> --keychain-profile $PROFILE"

rm -f "$ZIP"

# ── Staple ───────────────────────────────────────────────────────────────────
# Without this the app phones Apple on first launch and fails offline.

echo "▸ Staple"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" | sed 's/^/  /'

# The real test: what Gatekeeper will say on a machine that has never seen it.
echo "▸ Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/  /'

# ── Package ──────────────────────────────────────────────────────────────────

if $MAKE_DMG; then
  echo "▸ DMG"
  DMG="$ROOT/build/Sundown.dmg"
  rm -f "$DMG"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Sundown" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"

  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "✓ $DMG"
else
  ZIP="$ROOT/build/Sundown.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "✓ $ZIP"
fi

echo
echo "✓ $APP — signed, notarised, stapled"
echo
echo "  Verify on a clean machine before announcing:"
echo "    curl -LO <release-url> && open Sundown.zip"
echo "  A Gatekeeper dialog there means something above lied."
