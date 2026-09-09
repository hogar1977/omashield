#!/bin/bash
#
# OmaShield — make sure the guard tools are installed.
#
# Installs aur-scanner and yay-guard from the AUR when they are missing. This
# is the only part of OmaShield that installs anything itself; everything
# else is configuration.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib-state.sh"

# Returns 0 when both tools are present (or were installed successfully).
ensure_tools() {
  local missing=()

  command -v aur-scan >/dev/null 2>&1 || missing+=("aur-scanner")
  aur_audit_bin >/dev/null 2>&1 || missing+=("yay-guard")

  if ((${#missing[@]} == 0)); then return 0; fi

  echo -e "\e[1;33mOmaShield needs ${missing[*]} from the AUR.\e[0m"
  if gum confirm --default=true \
    --affirmative="Install ${missing[*]} now" \
    --negative="Not now (OmaShield stays idle)"; then
    yay -S --noconfirm --needed "${missing[@]}"
    # Verify and report where the audit binary ended up.
    command -v aur-scan >/dev/null 2>&1 || {
      echo -e "\e[31maur-scanner did not install correctly.\e[0m" >&2
      return 1
    }
    aur_audit_bin >/dev/null 2>&1 || {
      echo -e "\e[31myay-guard did not install correctly.\e[0m" >&2
      return 1
    }
    return 0
  fi

  return 1
}