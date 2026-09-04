#!/usr/bin/env bash
# Run `sundown --watch` on a timer and notify when a session leaves something
# behind.
#
#   ./Scripts/install-watch.sh [--interval 900] [--uninstall]
#
# launchd rather than a resident daemon, deliberately. The research on notch
# and menu-bar apps in this category found idle CPU of 26–41% in the most
# popular one, traced to a permanently-running process with an animation loop.
# A tool whose pitch is "you are wasting resources you cannot see" cannot be
# the thing wasting them. This wakes up, reads the process table, and exits —
# a few hundred milliseconds every fifteen minutes.

set -euo pipefail

LABEL="dev.sundown.watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INTERVAL=900

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) INTERVAL="$2"; shift 2 ;;
        --uninstall)
            launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
            rm -f "$PLIST"
            echo "✓ removed $LABEL"
            exit 0
            ;;
        *) echo "usage: $0 [--interval SECONDS] [--uninstall]" >&2; exit 2 ;;
    esac
done

SUNDOWN="$(command -v sundown || true)"
[[ -n "$SUNDOWN" ]] || {
    echo "✗ sundown is not on PATH. Install it first:" >&2
    echo "    sudo cp build/sundown /usr/local/bin/" >&2
    exit 1
}

# The wrapper exists because launchd cannot branch on an exit code. Exit 10
# means "there is something worth saying"; anything else stays silent.
WRAPPER="$HOME/.config/sundown/notify.sh"
mkdir -p "$(dirname "$WRAPPER")"
cat > "$WRAPPER" <<WRAP
#!/usr/bin/env bash
# Written by install-watch.sh. Safe to edit — replace the notification with
# whatever you prefer.
OUT="\$("$SUNDOWN" --watch 2>/dev/null)" || CODE=\$?
CODE="\${CODE:-0}"
[[ "\$CODE" == "10" ]] || exit 0

TITLE="\$(printf '%s' "\$OUT" | head -1)"
# osascript because a bare CLI has no bundle identity to post a
# UNUserNotification with. The banner is attributed to Script Editor rather
# than to Sundown — cosmetic, and the honest trade for not shipping a resident
# app just to own a notification.
osascript -e "display notification \"Run: sundown --phase after -y\" with title \"\$TITLE\"" 2>/dev/null || true
WRAP
chmod +x "$WRAPPER"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$WRAPPER</string></array>
    <key>StartInterval</key><integer>$INTERVAL</integer>
    <!-- Not at load: the first run has no baseline and would be a no-op
         anyway, and starting work the instant someone logs in is rude. -->
    <key>RunAtLoad</key><false/>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✓ watching every $((INTERVAL / 60)) min"
echo
echo "  It stays silent unless an agent session ended AND left something behind."
echo "  Check state:  cat ~/.config/sundown/watch.json"
echo "  Test it now:  sundown --watch"
echo "  Remove:       $0 --uninstall"
