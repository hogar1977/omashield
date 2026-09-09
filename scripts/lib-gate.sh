#!/bin/bash
#
# OmaShield — scanner gate helpers.
#
# These run the two independent AUR reviewers (aur-scan and yay-guard) over a
# set of packages, print their reports for the user to see, and implement the
# explicit "greenlight" step that has to happen before anything is installed.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib-state.sh"

# Emergency bypass for a single command (also honoured by the native hooks):
# OMASHIELD_OFF=1 (legacy AUR_SHIELD_OFF=1 still works).
shield_bypassed() {
  [[ ${OMASHIELD_OFF:-} == "1" || ${AUR_SHIELD_OFF:-} == "1" || ${AUR_AUDIT_OFF:-} == "1" ]]
}

# Returns 0 when both tools are available.
gate_tools_ready() {
  command -v aur-scan >/dev/null 2>&1 && aur_audit_bin >/dev/null 2>&1
}

# gate_scan <pkg...>
#
# Prints both reviews for the given packages. Returns 0 when every package is
# clean (no high/critical findings), 1 when at least one review raised a
# high-or-critical finding.
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

# gate_greenlight <pkg...>
#
# Asks the user to explicitly greenlight the reviewed packages. Returns 0 to
# proceed, 1 to abort (nothing will be installed).
gate_greenlight() {
  local count=$#
  if ((count == 0)); then return 1; fi
  gum confirm --default=true \
    --affirmative="Proceed — install $count package(s)" \
    --negative="Cancel — nothing gets installed" \
    "OmaShield reviewed the packages above. Greenlight the installation?"
}
