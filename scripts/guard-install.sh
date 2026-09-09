#!/bin/bash
#
# OmaShield — guarded AUR installer (used from Install > AUR).
#
# The interactive picker is the same fuzzy finder omarchy ships; what changes
# is what happens between picking and installing:
#
#   1. Pick AUR packages with fzf (multi-select with Tab / Space).
#   2. aur-scan and yay-guard review every picked package.
#   3. You greenlight (or cancel) — and only then is sudo asked and the
#      installation started.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib-state.sh"
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib-gate.sh"
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/ensure-tools.sh"

guard_aur_install() {
  ensure_tools || return 1

  # Same fzf presentation as the stock omarchy AUR picker.
  local fzf_args=(
    --multi
    --preview 'yay -Siia {1}'
    --preview-label='alt-p: toggle description, alt-b/B: toggle PKGBUILD, alt-j/k: scroll, tab: multi-select'
    --preview-label-pos='bottom'
    --preview-window 'down:65%:wrap'
    --bind 'alt-p:toggle-preview'
    --bind 'alt-d:preview-half-page-down,alt-u:preview-half-page-up'
    --bind 'alt-k:preview-up,alt-j:preview-down'
    --bind 'alt-b:change-preview:yay -Gpa {1} | tail -n +5'
    --bind 'alt-B:change-preview:yay -Siia {1}'
    --color 'pointer:green,marker:green'
  )

  local pkg_names
  pkg_names=$(yay -Slqa | fzf "${fzf_args[@]}")
  [[ -n $pkg_names ]] || return 0

  local names=()
  while IFS= read -r p; do
    [[ -n $p ]] && names+=("$p")
  done <<< "$pkg_names"

  echo -e "\e[1;36m\nSelected AUR package(s): ${names[*]}\e[0m\n"

  if ! gate_tools_ready; then ensure_tools || return 1; fi

  if ! gate_scan "${names[@]}"; then
    echo
    if ! gum confirm --default=false \
      --affirmative="Force install anyway" \
      --negative="Cancel the installation" \
      "High/critical findings were reported above. Force the installation?"; then
      echo -e "\e[1;31mInstallation cancelled — nothing was installed.\e[0m"
      return 1
    fi
    echo -e "\e[33mForcing the risky package(s) — your explicit choice.\e[0m"
  fi

  echo
  if ! gate_greenlight "${names[@]}"; then
    echo -e "\e[1;31mInstallation cancelled — nothing was installed.\e[0m"
    return 1
  fi

  # By this point the user greenlighted: ask for sudo, then install.
  # The stock flow assumes this helper exists; fall back to an inline
  # keepalive so a missing helper degrades to one sudo prompt, not a hang.
  if command -v omarchy-sudo-keepalive >/dev/null 2>&1; then
    source omarchy-sudo-keepalive
  else
    echo -e "\e[33momarchy-sudo-keepalive is missing — falling back to a plain sudo prompt.\e[0m"
    sudo -v || return 1
    while true; do sudo -n true; sleep 60; done 2>/dev/null &
    local keepalive_pid=$!
    trap "kill $keepalive_pid 2>/dev/null" RETURN
  fi

  echo "$pkg_names" | sed 's/^/aur\//' | tr '\n' ' ' | xargs yay -S --noconfirm --needed
  sudo updatedb --prune-bind-mounts=no --add-prunepaths=/.snapshots
  omarchy-show-done
}

# Run only when invoked directly.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  guard_aur_install
fi