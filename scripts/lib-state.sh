#!/bin/bash
# OmaShield — paths, ON/OFF state, and first-ON wiring (all reversible).

# --- Where things live ------------------------------------------------------

# Symlinked copies always resolve to the real plugin directory.
SHIELD_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPTS_DIR="$(dirname "$SHIELD_SELF")"
PLUGIN_DIR="$(dirname "$SCRIPTS_DIR")"
PLUGIN_ID="$(basename "$PLUGIN_DIR")"

# Command installed as ~/.local/bin/omarchy-omashield.
CMD_NAME="omarchy-omashield"

STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omashield"
STATE_FILE="$STATE_DIR/state"                 # enabled=1 | enabled=0
PENDING_AUR_FILE="$STATE_DIR/pending-aur"     # selected AUR packages
PENDING_REPO_FILE="$STATE_DIR/pending-repo"   # selected repo packages
PENDING_MISE_FILE="$STATE_DIR/pending-mise"   # selected mise tools
SEEN_REPO_FILE="$STATE_DIR/seen-repo"         # full repo list offered in the picker
SCANNED_AUR_FILE="$STATE_DIR/scanned-aur"     # reviewed AUR set (stage stamp)
SHADOW_DIR="$STATE_DIR/bin"                   # PATH shadow dir (update stages)

EXT_MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
YAY_INIT="$HOME/.config/yay/init.lua"
CMD_BIN="$HOME/.local/bin/$CMD_NAME"

MENU_STOCK_FILE="$STATE_DIR/menu-stock.json"  # pre-shield menu values, for restore

# Marker recognising our own hook/menu so uninstall never touches anyone
# else's. Mirrors manifest.json x-aurDependencies.
SHIELD_MARKER="OmaShield"
SHIELD_DEPS=(aur-scanner yay-guard)

mkdir -p "$STATE_DIR"

# --- State ------------------------------------------------------------------

# True when the shield is ON.
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

# Missing hard dependencies, one per line (empty = all present).
shield_missing_deps() {
  local missing=()
  command -v aur-scan >/dev/null 2>&1 || missing+=("aur-scanner")
  aur_audit_bin >/dev/null 2>&1 || missing+=("yay-guard")
  printf '%s\n' "${missing[@]}"
}

# Whether the bar widget is enabled: "true", "false", or "unknown".
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

# The --ignore list the stock AUR stage passes to yay, parsed live.
stock_aur_ignore() {
  local ign
  ign=$(grep -oP '(?<=--ignore[ =])[^ "\"'"'"']+' /usr/share/omarchy/bin/omarchy-update-aur-pkgs 2>/dev/null | head -n1)
  printf '%s' "${ign:-}"
}

# Pending repo update names, one per line (last-synced DB, no elevation).
list_repo_updates() {
  pacman -Qu 2>/dev/null | awk '{print $1}'
}

# Pending AUR update names, minus the stock ignore list (live RPC).
list_aur_updates() {
  local raw stock_ignore
  raw=$(yay -Qua 2>/dev/null | awk '{print $1}')
  stock_ignore=$(stock_aur_ignore)
  if [[ -z $stock_ignore ]]; then
    printf '%s\n' "$raw" | sed '/^$/d'
  else
    printf '%s\n' "$raw" | sed '/^$/d' | grep -vxF -f <(tr ',' '\n' <<< "$stock_ignore") || true
  fi
}

# --- First-ON wiring (idempotent; user-owned paths only) --------------------

# CLI symlink. The panel uses the absolute path, so this may run first.
shield_ensure_symlink() {
  mkdir -p "$(dirname "$CMD_BIN")"
  ln -sf "$SCRIPTS_DIR/aur-shield" "$CMD_BIN"
}

# True when the yay hook file is one we installed.
shield_hook_is_ours() {
  [[ -f $YAY_INIT ]] && grep -q "$SHIELD_MARKER" "$YAY_INIT" 2>/dev/null
}

# Install our yay hook, backing up a genuine pre-existing user hook first.
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

# (Re)create the dispatch shadow symlinks (inert while OFF).
shield_ensure_shadow() {
  mkdir -p "$SHADOW_DIR"
  ln -sf "$SCRIPTS_DIR/update-aur-pkgs.sh" "$SHADOW_DIR/omarchy-update-aur-pkgs"
  ln -sf "$SCRIPTS_DIR/update-system-pkgs.sh" "$SHADOW_DIR/omarchy-update-system-pkgs"
  ln -sf "$SCRIPTS_DIR/update-mise.sh" "$SHADOW_DIR/omarchy-update-mise"
}

# Route the menu's Update / Install>AUR through the shield (ON), capturing
# pre-shield values once for restore.
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
shield_entries = {
    "update.omarchy": {"icon": "\ue900", "iconFont": "omarchy", "label": "Omarchy", "action": SHIELD + " update"},
    "install.aur":    {"icon": "\U000f08c7", "label": "AUR", "action": SHIELD + " install-aur"},
}

data = load(menu)

if any("omarchy-omashield" in (data.get(k) or {}).get("action", "") for k in shield_entries):
    raise SystemExit(0)

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

# Restore the stock menu (uninstall only).
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
    if "omarchy-omashield" in (data.get(k) or {}).get("action", ""):
        data[k] = stock_d.get(k, fallback[k])
        changed = True
if changed:
    menu.write_text(json.dumps(data, indent=2) + "\n")
PYEOF
}

# All first-ON wiring. Idempotent — safe to re-run on every ON.
shield_ensure_routing() {
  shield_ensure_symlink
  shield_ensure_hook
  shield_menu_shield
  shield_ensure_shadow
}

# ON: gate on hard deps first (exit 3), then wire, then flip state.
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

# OFF: state file only. Hooks/shadows are state-gated (go inert); the menu
# keeps routing through the CLI, which bypasses to stock.
shield_deactivate() {
  shield_state_off
}
