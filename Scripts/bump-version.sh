#!/usr/bin/env bash
# Set the version in every place it appears, from one argument.
#
#   ./Scripts/bump-version.sh 0.2.0
#
# Three files carry the version, and a release where they disagree is the kind
# of bug that only surfaces in a support thread six weeks later. This writes
# all three; `--check` verifies they agree without changing anything, which is
# what release.sh calls.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT/Sources/Sundown/Resources/Info.plist"
MAIN="$ROOT/Sources/SundownCLI/main.swift"
VERSION_FILE="$ROOT/VERSION"

read_plist() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST"; }
read_main()  { sed -nE 's/^let version = "(.+)"$/\1/p' "$MAIN"; }
read_file()  { tr -d '[:space:]' < "$VERSION_FILE"; }

if [[ "${1:-}" == "--check" ]]; then
    v_file="$(read_file)"; v_plist="$(read_plist)"; v_main="$(read_main)"
    if [[ "$v_file" == "$v_plist" && "$v_file" == "$v_main" ]]; then
        echo "  version: $v_file (consistent)"
        exit 0
    fi
    echo "✗ Version mismatch — run ./Scripts/bump-version.sh <version>" >&2
    echo "    VERSION:    $v_file"    >&2
    echo "    Info.plist: $v_plist"   >&2
    echo "    main.swift: $v_main"    >&2
    exit 1
fi

NEW="${1:-}"
[[ -n "$NEW" ]] || { echo "usage: $0 <version> | --check" >&2; exit 1; }
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "✗ '$NEW' is not semver (x.y.z)" >&2; exit 1; }

echo "$NEW" > "$VERSION_FILE"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW" "$PLIST"
# CFBundleVersion must increase monotonically for every build Apple sees.
# Tying it to the marketing version is the simplest rule that satisfies that
# and stays legible in a crash report.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW" "$PLIST"

# -i '' is the BSD sed form. This script is macOS-only anyway — it drives
# PlistBuddy two lines up.
sed -i '' -E "s/^let version = \".+\"$/let version = \"$NEW\"/" "$MAIN"

echo "✓ $NEW written to VERSION, Info.plist, main.swift"
echo
echo "  Next:  git commit -am \"Version $NEW\" && git tag v$NEW && git push --tags"
echo "  The tag is what triggers the release workflow."
