#!/bin/bash
#
# OmaShield — shared state and path helpers.
#
# This file is sourced by the omashield CLI and the helper scripts. It owns
# every path OmaShield touches so uninstall can reliably reverse what the
# first-ON wiring put in place.

# --- Where things live ------------------------------------------------------

# This library resolves itself through readlink so symlinked copies (the
# shadow command is a symlink) always land on the real plugin directory.
SHIELD_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPTS_DIR="$(dirname "$SHIELD_SELF")"
PLUGIN_DIR="$(dirname "$SCRIPTS_DIR")"
PLUGIN_ID="$(basename "$PLUGIN_DIR")"

# Canonical command name. Upgraders from dalibor.aur-shield may still have the
# legacy binary name floating around; it is migrated, never used.
CMD_NAME="omarchy-omashield"
LEGACY_CMD_NAME="omarchy-aur-shield"

# Runtime state (created lazily, safe to delete any time).
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omashield"
STATE_FILE="$STATE_DIR/state"                 # enabled=1 | enabled=0
PENDING_AUR_FILE="$STATE_DIR/pending-aur"     # selected AUR packages, one per line
PENDING_REPO_FILE="$STATE_DIR/pending-repo"   # selected repo packages, one per line
SCANNED_AUR_FILE="$STATE_DIR/scanned-aur"     # AUR set reviewed by the gate, one per line
SHADOW_DIR="$STATE_DIR/bin"                   # PATH shadow dir (omarchy update stages)

# Pre-rename state dir (dalibor.aur-shield era). Migrated once, then ignored.
LEGACY_STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aur-shield"

# Files OmaShield integrates with on the live system.
EXT_MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
YAY_INIT="$HOME/.config/yay/init.lua"
CMD_BIN="$HOME/.local/bin/$CMD_NAME"
LEGACY_CMD_BIN="$HOME/.local/bin/$LEGACY_CMD_NAME"

# Menu entries stock values captured the first time the shield takes over, so
# uninstall can hand the menu back exactly what it had.
MENU_STOCK_FILE="$STATE_DIR/menu-stock.json"

# Marker string used to recognise hooks/menus we own (so uninstall never
# touches something that belongs to another tool). The legacy marker covers
# hooks installed by dalibor.aur-shield before the rename.
SHIELD_MARKER="OmaShield"
LEGACY_SHIELD_MARKER="AUR Shield"

# Hard dependencies (mirrors manifest.json x-aurDependencies; the ON gate
# refuses to arm while any of these are missing).
SHIELD_DEPS=(aur-scanner yay-guard)

# Migrate before creating: a fresh source must not pre-create the new dir and
# shadow a pre-rename state dir waiting to be moved.
if [[ -d $LEGACY_STATE_DIR && ! -e $STATE_DIR ]]; then
  mv "$LEGACY_STATE_DIR" "$STATE_DIR"
fi

mkdir -p "$STATE_DIR"

# --- State ------------------------------------------------------------------

# Returns 0 when the shield is ON, 1 when OFF (or unset).
shield_state_is_on() {
  [[ -f $STATE_FILE ]] && grep -q '^enabled=1$' "$STATE_FILE"
}

shield_state_on() {
  mkdir -p "$STATE_DIR"
  printf 'enabled=1\n' > "$STATE_FILE"
}

shield_state_off() {
  mkdir -p "$STATE_DIR"
  printf 'enabled=0\n' > "$STATE_FILE"
}

# One-time move of the pre-rename state dir. Idempotent.
shield_migrate_state_dir() {
  if [[ -d $LEGACY_STATE_DIR && ! -e $STATE_DIR ]]; then
    mv "$LEGACY_STATE_DIR" "$STATE_DIR"
  fi
}

# --- Resolve installed tools -------------------------------------------------

# Locate the yay-guard audit binary wherever the package put it.
aur_audit_bin() {
  local candidates=(
    "$HOME/.local/bin/aur_audit.py"
    "/usr/local/bin/aur_audit.py"
    "/usr/bin/aur_audit.py"
    "/usr/share/yay-guard/aur_audit.py"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -x $c ]]; then printf '%s\n' "$c"; return 0; fi
  done
  command -v aur_audit.py 2>/dev/null && return 0
  return 1
}

# Names of hard dependencies that are currently missing (empty = all present).
shield_missing_deps() {
  local missing=()
  command -v aur-scan >/dev/null 2>&1 || missing+=("aur-scanner")
  aur_audit_bin >/dev/null 2>&1 || missing+=("yay-guard")
  printf '%s\n' "${missing[@]}"
}

# --- Widget enabled state (option E) ----------------------------------------

# Reports whether this plugin's bar widget is currently enabled in the shell:
# prints "true", "false", or "unknown" (shell unreachable — fail open).
plugin_widget_enabled() {
  local out
  out=$(omarchy plugin list --json 2>/dev/null \
    | jq -r --arg id "$PLUGIN_ID" '.[] | select(.id == $id) | .enabled | tostring' 2>/dev/null)
  if [[ $out == "true" || $out == "false" ]]; then
    printf '%s\n' "$out"
  else
    printf 'unknown\n'
  fi
}

# --- Stock omarchy behaviour -------------------------------------------------

# The --ignore list the stock AUR stage passes to yay, parsed from the stock
# script at runtime so we never drift out of sync with upstream.
stock_aur_ignore() {
  local ign
  ign=$(grep -oP '(?<=--ignore[ =])[^ "\"'"'"']+' /usr/share/omarchy/bin/omarchy-update-aur-pkgs 2>/dev/null | head -n1)
  printf '%s' "${ign:-}"
}

# --- First-ON wiring (idempotent; all user-owned paths, no sudo) ------------

# The CLI entry point. The panel reaches the CLI by absolute path, so this can
# run before the symlink below exists.
shield_ensure_symlink() {
  mkdir -p "$(dirname "$CMD_BIN")"
  ln -sf "$SCRIPTS_DIR/aur-shield" "$CMD_BIN"
  # Drop the pre-rename binary name so two commands never diverge.
  if [[ -L $LEGACY_CMD_BIN ]]; then
    rm -f "$LEGACY_CMD_BIN"
  fi
}

# True when the yay hook file is one we installed (current or legacy marker).
shield_hook_is_ours() {
  [[ -f $YAY_INIT ]] && grep -q -e "$SHIELD_MARKER" -e "$LEGACY_SHIELD_MARKER" "$YAY_INIT" 2>/dev/null
}

# Install the native yay guard hook. A genuine pre-existing user hook is backed
# up first; a hook we installed (either era) is replaced without backup.
shield_ensure_hook() {
  mkdir -p "$(dirname "$YAY_INIT")"
  if shield_hook_is_ours; then
    cp "$PLUGIN_DIR/yay-init.lua" "$YAY_INIT"
    return 0
  fi
  if [[ -f $YAY_INIT ]]; then
    cp "$YAY_INIT" "$YAY_INIT.omashield-bak.$(date -u +%Y%m%d%H%M%S)"
  fi
  cp "$PLUGIN_DIR/yay-init.lua" "$YAY_INIT"
}

# (Re)create the dispatch shadow symlinks. Idempotent; the shadow PATH is only
# used when the shield is ON, so the symlinks sitting there while OFF is inert.
shield_ensure_shadow() {
  mkdir -p "$SHADOW_DIR"
  ln -sf "$SCRIPTS_DIR/update-aur-pkgs.sh" "$SHADOW_DIR/omarchy-update-aur-pkgs"
  ln -sf "$SCRIPTS_DIR/update-system-pkgs.sh" "$SHADOW_DIR/omarchy-update-system-pkgs"
}

# Point the menu's Update / Install>AUR at the shield (ON). Also migrates menu
# actions left behind by the pre-rename binary name.
shield_menu_shield() {
  python3 - "$EXT_MENU" "$MENU_STOCK_FILE" <<'PYEOF'
import json, re, sys
from pathlib import Path
menu, stock = Path(sys.argv[1]), Path(sys.argv[2])

def strip(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)

def load(p):
    if not p.exists() or p.stat().st_size == 0:
        return {}
    try:
        d = json.loads(strip(p.read_text()))
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}

SHIELD = "omarchy-launch-floating-terminal-with-presentation omarchy-omashield"
LEGACY = "omarchy-aur-shield"
shield_entries = {
    "update.omarchy": {"icon": "\ue900", "iconFont": "omarchy", "label": "Omarchy", "action": SHIELD + " update"},
    "install.aur":    {"icon": "\U000f08c7", "label": "AUR", "action": SHIELD + " install-aur"},
}

data = load(menu)

# One-time migration from the pre-rename binary name.
migrated = False
for k in shield_entries:
    action = (data.get(k) or {}).get("action", "")
    if LEGACY in action:
        data[k]["action"] = action.replace(LEGACY, "omarchy-omashield")
        migrated = True

if any("omarchy-omashield" in (data.get(k) or {}).get("action", "") for k in shield_entries):
    if migrated:
        menu.write_text(json.dumps(data, indent=2) + "\n")
    raise SystemExit(0)  # already routed through the shield

# Capture the pre-shield values once so uninstall can restore them exactly.
stock_d = load(stock)
if not stock_d:
    stock_d = {k: data.get(k) for k in shield_entries if k in data}
    if stock_d:
        stock.write_text(json.dumps(stock_d, indent=2) + "\n")

changed = False
for k, v in shield_entries.items():
    if data.get(k) != v:
        data[k] = v
        changed = True
if not changed:
    raise SystemExit(0)

ordered = {k: data[k] for k in load(menu) if k in data}
for k in data:
    if k not in ordered:
        ordered[k] = data[k]
menu.write_text(json.dumps(ordered, indent=2) + "\n")
PYEOF
}

# Hand the menu back to the stock commands (uninstall only). Installed but
# inert until then.
shield_menu_restore_stock() {
  python3 - "$EXT_MENU" "$MENU_STOCK_FILE" <<'PYEOF'
import json, re, sys
from pathlib import Path
menu, stock = Path(sys.argv[1]), Path(sys.argv[2])

def strip(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)

def load(p):
    if not p.exists() or p.stat().st_size == 0:
        return {}
    try:
        d = json.loads(strip(p.read_text()))
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}

fallback = {
    "update.omarchy": {"icon": "\ue900", "iconFont": "omarchy", "label": "Omarchy",
                       "action": "omarchy-launch-floating-terminal-with-presentation omarchy-update"},
    "install.aur":    {"icon": "\U000f08c7", "label": "AUR",
                       "action": "xdg-terminal-exec --app-id=org.omarchy.terminal omarchy-pkg-aur-install"},
}

data = load(menu)
stock_d = load(stock)
changed = False
for k in fallback:
    if "omarchy-omashield" in (data.get(k) or {}).get("action", "") \
       or "omarchy-aur-shield" in (data.get(k) or {}).get("action", ""):
        data[k] = stock_d.get(k, fallback[k])
        changed = True
if changed:
    menu.write_text(json.dumps(data, indent=2) + "\n")
PYEOF
}

# The whole first-ON wiring: state-dir migration, symlink, hook, menu routing,
# dispatch shadows. Idempotent — safe to re-run on every ON.
shield_ensure_routing() {
  shield_migrate_state_dir
  shield_ensure_symlink
  shield_ensure_hook
  shield_menu_shield
  shield_ensure_shadow
}

# The whole ON switch: ON-gate first (hard deps, no TTY-safe install here),
# then wiring, then state. Never touches packages.
shield_activate() {
  local missing
  missing=$(shield_missing_deps)
  if [[ -n $missing ]]; then
    printf 'missing: %s\n' "$(tr '\n' ' ' <<< "$missing")" >&2
    return 3
  fi
  shield_ensure_routing
  shield_state_on
}

# The whole OFF switch: state file only. Hooks and the dispatch shadow are
# state-gated, so they go inert on their own; the menu keeps routing through
# the CLI, which bypasses straight to stock. Everything stays installed.
shield_deactivate() {
  shield_state_off
}
