#!/usr/bin/env bash
# Builds Sundown.app from the SwiftPM executable.
#
# MenuBarExtra needs a real bundle (for LSUIElement) and SMAppService needs a
# bundle identifier, so a bare `swift build` binary won't do. This assembles
# the smallest correct .app around it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/Sundown.app"

echo "▸ Building ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
# SundownApp, not Sundown — see the comment in Package.swift. On a
# case-insensitive filesystem the two products would be one file, and the CLI
# would silently become the GUI.
BIN="$BIN_DIR/SundownApp"
CLI="$BIN_DIR/sundown"
[ -x "$BIN" ] || { echo "✗ No binary at $BIN"; exit 1; }
[ -x "$CLI" ] || { echo "✗ No CLI at $CLI"; exit 1; }

# Cheap assertion against the bug ever coming back: the CLI must answer
# --version in well under a second. If these two products ever collide again,
# this hangs in the AppKit run loop instead, and the build stops here rather
# than shipping a CLI that opens a window.
"$CLI" --version >/dev/null 2>&1 &
CLI_PID=$!
for _ in $(seq 1 25); do            # 25 × 0.2s = 5s ceiling, exits as soon as done
  kill -0 "$CLI_PID" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$CLI_PID" 2>/dev/null; then
  kill -9 "$CLI_PID" 2>/dev/null || true
  echo "✗ '$CLI --version' did not exit."
  echo "  The CLI and app products have collided again — on a case-insensitive"
  echo "  filesystem they become one file. See the note in Package.swift."
  exit 1
fi
wait "$CLI_PID" 2>/dev/null || true

echo "▸ Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Sundown"
cp "$ROOT/Sources/Sundown/Resources/Info.plist" "$APP/Contents/Info.plist"

# Icon. Regenerated each build so a change to make_icon.py can't silently
# ship the previous artwork.
#
# Checking `python3` exists is not enough — Pillow is a third-party import, and
# under `set -e` a missing module aborted the whole bundle after the binary was
# already in place, leaving a half-assembled .app that still signed cleanly.
# The icon is cosmetic; the bundle is not. Probe the actual import, and keep
# the failure non-fatal but loud.
#
# Pillow is the only third-party dependency in this repo and it exists solely
# to draw the icon. Modern Pythons are PEP 668 "externally managed", so a plain
# pip install fails and --break-system-packages is a rude thing to do to
# somebody's machine over an icon. A throwaway venv under build/ costs one
# download, is cached across builds, and disappears with `rm -rf build`.
ICON_PY=""
if python3 -c "import PIL" >/dev/null 2>&1; then
  ICON_PY="python3"
elif command -v iconutil >/dev/null 2>&1; then
  VENV="$ROOT/build/.iconenv"
  if [ ! -x "$VENV/bin/python3" ]; then
    echo "▸ Icon deps (one-time venv, Pillow only)"
    python3 -m venv "$VENV" >/dev/null 2>&1 &&
      "$VENV/bin/pip" install --quiet pillow >/dev/null 2>&1 || true
  fi
  [ -x "$VENV/bin/python3" ] && "$VENV/bin/python3" -c "import PIL" >/dev/null 2>&1 &&
    ICON_PY="$VENV/bin/python3"
fi

if [ -n "$ICON_PY" ] && command -v iconutil >/dev/null 2>&1; then
  echo "▸ Icon"
  if "$ICON_PY" "$ROOT/Scripts/make_icon.py" >/dev/null 2>&1 &&
     iconutil -c icns "$ROOT/build/Sundown.iconset" \
       -o "$APP/Contents/Resources/Sundown.icns" 2>/dev/null; then
    echo "  generated"
  else
    echo "  ✗ generation failed — bundle will show the generic app icon"
  fi
else
  echo "▸ Icon skipped — needs iconutil and Pillow"
fi

# SwiftPM resource bundles sit beside the binary; carry any into Resources.
# `nullglob` so an unmatched pattern expands to nothing rather than to itself —
# under `set -e` the naive `[ -e "$f" ] && cp` form exits the script.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

# The headless CLI ships beside the app, not inside it — it belongs on PATH.
if [ -x "$CLI" ]; then
  cp "$CLI" "$ROOT/build/sundown"
  echo "▸ CLI at build/sundown"
fi

# Ad-hoc signature. Enough for local use and for SMAppService to register.
# Replace with your Developer ID before distributing to anyone else.
echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "✓ $APP"
echo
echo "  Run:      open '$APP'"
echo "  Install:  cp -R '$APP' /Applications/"
echo "  CLI:      sudo cp '$ROOT/build/sundown' /usr/local/bin/"
echo "  Try:      '$ROOT/build/sundown' --dry-run"
