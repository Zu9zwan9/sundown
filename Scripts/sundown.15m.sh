#!/usr/bin/env bash
# SwiftBar / xbar plugin — ambient, no app required.
#
#   brew install --cask swiftbar
#   cp Scripts/sundown.15m.sh <your SwiftBar plugin folder>   # Preferences names it
#
# The refresh interval is the filename: 15m. Rename it to change it.
# Both SwiftBar and xbar read this format, so the same file works in either.
#
# Prints nothing but a moon unless there is something to say. A status item
# that always shows a number is a number you stop reading.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v sundown >/dev/null || { echo "🌙 ?"; echo "---"; echo "sundown not on PATH"; exit 0; }

IDLE="$(sundown --idle 2>/dev/null)"
COUNT="$(printf '%s\n' "$IDLE" | sed -n 's/^ *\([0-9][0-9]*\) of [0-9][0-9]* connected.*/\1/p' | head -1)"

if [[ -n "$COUNT" && "$COUNT" -gt 0 ]]; then
  echo "🌙 $COUNT"
else
  echo "🌙"
fi

echo "---"
printf '%s\n' "$IDLE"
echo "---"
echo "Snapshot a baseline | bash=sundown param1=--snapshot terminal=true"
echo "Compare against it | bash=sundown param1=--compare terminal=true"
echo "End what's left running | bash=sundown param1=--dry-run terminal=true"
echo "Refresh | refresh=true"
