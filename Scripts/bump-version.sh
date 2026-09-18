#!/usr/bin/env bash
# Set the version in every place it appears, from one argument.
#
#   ./Scripts/bump-version.sh 0.2.0
#
# Two files carry the version, and a release where they disagree is the kind of
# bug that only surfaces in a support thread six weeks later. This writes both;
# `--check` verifies they agree, which is what release-cli.sh calls.
#
# There used to be a third: the menu bar app's Info.plist. The app was removed
# on 2026-09-18 and this script kept writing to a file that no longer exists,
# so a bump wrote VERSION, failed on the plist, and left main.swift behind.
# That is the exact split this script exists to prevent.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="$ROOT/Sources/SundownCLI/main.swift"
VERSION_FILE="$ROOT/VERSION"

read_main()  { sed -nE 's/^let version = "(.+)"$/\1/p' "$MAIN"; }
read_file()  { tr -d '[:space:]' < "$VERSION_FILE"; }

if [[ "${1:-}" == "--check" ]]; then
    v_file="$(read_file)"; v_main="$(read_main)"
    if [[ "$v_file" == "$v_main" ]]; then
        echo "  version: $v_file (consistent)"
        exit 0
    fi
    echo "✗ Version mismatch — run ./Scripts/bump-version.sh <version>" >&2
    echo "    VERSION:    $v_file"    >&2
    echo "    main.swift: $v_main"    >&2
    exit 1
fi

NEW="${1:-}"
[[ -n "$NEW" ]] || { echo "usage: $0 <version> | --check" >&2; exit 1; }
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "✗ '$NEW' is not semver (x.y.z)" >&2; exit 1; }

echo "$NEW" > "$VERSION_FILE"

# -i '' is the BSD sed form. This script is macOS-only anyway.
sed -i '' -E "s/^let version = \".+\"$/let version = \"$NEW\"/" "$MAIN"

echo "✓ $NEW written to VERSION and main.swift"
echo
echo "  Next:  git commit -am \"Version $NEW\" && git tag v$NEW && git push --tags"
echo "  The tag is what triggers the release workflow."
