#!/bin/bash
# Wire claude-config/ into ~/.claude: operating rules (CLAUDE.md import),
# the context-guard UserPromptSubmit hook, and the status line. Idempotent —
# run once after cloning, and again only if paths change. `git pull` updates
# the rules and scripts in place afterwards (they are referenced, not copied).

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/claude-config"
CLAUDE_DIR="${HOME}/.claude"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

mkdir -p "${CLAUDE_DIR}"
chmod +x "${CONFIG_DIR}/hooks/context-guard.py" "${CONFIG_DIR}/statusline.py"

# 1. Operating rules: import from the repo so `git pull` updates them.
IMPORT_LINE="@${CONFIG_DIR}/CLAUDE.md"
USER_MD="${CLAUDE_DIR}/CLAUDE.md"
if [ -f "${USER_MD}" ] && grep -qF "${IMPORT_LINE}" "${USER_MD}"; then
    echo -e "${GREEN}CLAUDE.md import already present.${NC}"
else
    { [ -f "${USER_MD}" ] && echo ""; echo "${IMPORT_LINE}"; } >> "${USER_MD}"
    echo -e "${GREEN}Added operating-rules import to ${USER_MD}.${NC}"
fi

# 2. Hook + status line in settings.json (merged, never clobbered).
python3 - "${CLAUDE_DIR}/settings.json" "${CONFIG_DIR}" <<'PY'
import json, os, shutil, sys

settings_path, config_dir = sys.argv[1], sys.argv[2]
settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)
    shutil.copy2(settings_path, settings_path + ".bak")

changed = []

hook_cmd = os.path.join(config_dir, "hooks", "context-guard.py")
entries = settings.setdefault("hooks", {}).setdefault("UserPromptSubmit", [])
if not any("context-guard" in h.get("command", "")
           for e in entries for h in e.get("hooks", [])):
    entries.append({"matcher": "*", "hooks": [
        {"type": "command", "command": hook_cmd, "timeout": 10}]})
    changed.append("context-guard hook")

sl_cmd = os.path.join(config_dir, "statusline.py")
if "statusLine" not in settings:
    settings["statusLine"] = {"type": "command", "command": sl_cmd}
    changed.append("status line")
elif "statusline.py" not in settings["statusLine"].get("command", ""):
    print("NOTE: an existing statusLine is configured; leaving it alone. "
          f"Point it at {sl_cmd} manually if you want this one.")

if changed:
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print("Installed: " + ", ".join(changed) + f" -> {settings_path}")
else:
    print("settings.json already up to date.")
PY

echo -e "${GREEN}Done. Takes effect on the next Claude Code launch.${NC}"
echo -e "${YELLOW}Uninstall: remove the import line from ~/.claude/CLAUDE.md and the context-guard/statusLine entries from ~/.claude/settings.json.${NC}"
