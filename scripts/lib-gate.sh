#!/bin/bash
# OmaShield — scanner gate: review AUR sets with both tools, then greenlight.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib-state.sh"

# Single-command bypass, also honoured by the native hooks.
shield_bypassed() {
  [[ ${OMASHIELD_OFF:-} == "1" || ${AUR_AUDIT_OFF:-} == "1" ]]
}

# True when both guard tools are available.
gate_tools_ready() {
  command -v aur-scan >/dev/null 2>&1 && aur_audit_bin >/dev/null 2>&1
}

# Tell the user to install the tools themselves, then switch the shield OFF.
tools_missing_notice() {
  local missing
  missing=$(shield_missing_deps | tr '\n' ' ')
  echo -e "\e[1;31mOmaShield needs ${missing:-aur-scanner yay-guard} before it can proceed.\e[0m" >&2
  echo -e "Install them through the standard procedure (Omarchy Menu > Install > AUR," >&2
  echo -e "or yay -S aur-scanner yay-guard), then switch OmaShield ON again." >&2
  shield_state_off
  echo -e "\e[33mOmaShield has switched itself OFF — stock behaviour applies until then.\e[0m" >&2
}

# Abort when the tools are missing. Never installs anything.
require_tools() {
  gate_tools_ready || { tools_missing_notice; return 1; }
}

# Print both tool reviews. Returns 0 when clean, 1 on high/critical findings.
gate_scan() {
  local pkgs=("$@")
  if ((${#pkgs[@]} == 0)); then return 0; fi

  local audit_bin rc_a=0 rc_y=0
  audit_bin="$(aur_audit_bin 2>/dev/null)"

  echo -e "\e[1;36m── [1/2] aur-scan — static analysis and full dependency tree ──\e[0m"
  aur-scan check "${pkgs[@]}" --fail-on high --no-color
  rc_a=$?

  echo
  echo -e "\e[1;36m── [2/2] yay-guard — heuristics and AUR metadata ──\e[0m"
  if [[ -n $audit_bin && -x $audit_bin ]]; then
    "$audit_bin" check "${pkgs[@]}" --fail-on high --no-ai
    rc_y=$?
  else
    echo -e "\e[33m yay-guard (aur_audit.py) is not installed — only aur-scan ran.\e[0m"
    rc_y=1
  fi

  echo
  if [[ $rc_a -eq 0 && $rc_y -eq 0 ]]; then
    echo -e "\e[1;32m✓ No high/critical findings for ${#pkgs[@]} package(s).\e[0m"
    return 0
  fi

  echo -e "\e[1;31m▲ High/critical finding(s) reported above for ${#pkgs[@]} package(s).\e[0m"
  return 1
}

# Explicit user greenlight. Returns 0 to proceed, 1 to abort.
gate_greenlight() {
  local count=$#
  if ((count == 0)); then return 1; fi
  gum confirm --default=true \
    --affirmative="Proceed — install $count package(s)" \
    --negative="Cancel — nothing gets installed" \
    "OmaShield reviewed the packages above. Greenlight the installation?"
}
