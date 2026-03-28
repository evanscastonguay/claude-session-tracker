#!/usr/bin/env bash
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"

echo "Removing Claude Tracker hooks..."

python3 << 'PYEOF'
import json, os

settings_path = f"{os.environ['HOME']}/.claude/settings.json"

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
tracker_tag = "claude-tracker"
removed = 0

for event in list(hooks.keys()):
    matchers = hooks[event]
    new_matchers = []
    for m in matchers:
        new_hooks = [h for h in m.get("hooks", []) if tracker_tag not in h.get("command", "")]
        if new_hooks:
            m["hooks"] = new_hooks
            new_matchers.append(m)
        else:
            removed += 1
    if new_matchers:
        hooks[event] = new_matchers
    else:
        del hooks[event]

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print(f"Removed {removed} tracker hooks.")
PYEOF

echo "Done!"
