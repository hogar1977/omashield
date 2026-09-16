#!/bin/bash
# OmaShield — guarded AUR installer: fzf pick, scan both tools, greenlight,
# then yay installs (yay handles elevation itself).

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib-state.sh"
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib-gate.sh"

guard_aur_install() {
  require_tools || return 1

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

  require_tools || return 1

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

  # Greenlit: install (locate-db refresh stays on its regular schedule).
  echo "$pkg_names" | sed 's/^/aur\//' | tr '\n' ' ' | xargs yay -S --noconfirm --needed
}

# Run only when invoked directly.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  guard_aur_install
fi