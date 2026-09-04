#!/usr/bin/env bash
# Build the CLI release asset the npm package fetches, and record its checksum.
#
#   ./Scripts/release-cli.sh
#   gh release upload "v$(cat VERSION)" build/sundown-macos-*.tar.gz
#   npm publish
#
# Separate from release.sh, which notarises the .app. The CLI needs signing but
# not notarisation: it is fetched by a package manager rather than opened from
# Finder, so Gatekeeper's quarantine path never applies.
#
# The checksum is written into package.json because bin/sundown.js refuses to
# execute a download it cannot verify. A release built without running this is
# a release npx will decline to run, which is the intended failure.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION)"
ARCH="$([[ "$(uname -m)" == "arm64" ]] && echo arm64 || echo x64)"
IDENTITY="${SIGN_IDENTITY:-}"

echo "▸ Build $VERSION for $ARCH"
swift build -c release --product sundown

BIN=".build/release/sundown"
if [[ -n "$IDENTITY" ]]; then
  echo "▸ Sign as $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BIN"
  codesign --verify --strict "$BIN"
else
  echo "▸ No SIGN_IDENTITY set — shipping an unsigned binary."
  echo "  Fine for a personal tap; set SIGN_IDENTITY='Developer ID Application: …' to sign."
fi

mkdir -p build
ASSET="build/sundown-macos-$ARCH.tar.gz"
tar -czf "$ASSET" -C .build/release sundown

SHA="$(shasum -a 256 "$ASSET" | cut -d' ' -f1)"
echo "▸ $ASSET"
echo "  sha256 $SHA"

# Rewritten in place so the published package and the uploaded asset cannot
# disagree. Node rather than sed: package.json is JSON, and a regex that edits
# JSON is a bug waiting for a reformat.
node -e '
  const fs = require("fs");
  const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
  pkg.version = process.argv[1];
  pkg.checksums = pkg.checksums || {};
  pkg.checksums[process.argv[2]] = process.argv[3];
  fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");
' "$VERSION" "$ARCH" "$SHA"

echo "▸ package.json updated — version $VERSION, checksums.$ARCH"
echo
echo "Next:"
echo "  gh release upload v$VERSION $ASSET"
echo "  npm publish            # publishes sundown-cli"
