#!/usr/bin/env bash
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
BACKUP="$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
TRACKER_HOOK='curl -s -X POST http://localhost:7429/events -H '\''Content-Type: application/json'\'' -d @- > /dev/null 2>&1 &'

echo "Installing Claude Tracker hooks..."
echo "Backing up $SETTINGS to $BACKUP"
cp "$SETTINGS" "$BACKUP"

# Use python3 to merge hooks into existing settings.json
python3 << 'PYEOF'
import json, sys

settings_path = sys.argv[1] if len(sys.argv) > 1 else f"{__import__('os').environ['HOME']}/.claude/settings.json"

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})
tracker_hook_cmd = "curl -s -X POST http://localhost:7429/events -H 'Content-Type: application/json' -d @- > /dev/null 2>&1 &"
tracker_tag = "claude-tracker"

# Events to hook into
events = {
    "Stop": "",
    "Notification": "idle_prompt",
    "UserPromptSubmit": "",
    "SessionEnd": "",
}

for event, matcher in events.items():
    matchers = hooks.setdefault(event, [])

    # Check if tracker hook already exists
    already_installed = False
    for m in matchers:
        for h in m.get("hooks", []):
            if tracker_tag in h.get("command", ""):
                already_installed = True
                break

    if not already_installed:
        matchers.append({
            "matcher": matcher,
            "hooks": [{
                "type": "command",
                "command": f"curl -s -X POST http://localhost:7429/events -H 'Content-Type: application/json' -d @- > /dev/null 2>&1 & # {tracker_tag}"
            }]
        })
        print(f"  Added {event} hook")
    else:
        print(f"  {event} hook already installed")

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("Done! Hooks installed.")
PYEOF

echo ""
echo "Hooks are installed. They will take effect for new Claude turns."
echo "Backup saved to: $BACKUP"
