#!/bin/bash
#
# OmaShield — drop-in replacement for omarchy-update-aur-pkgs.
#
# The first-ON wiring symlinks this file from a PATH-shadow directory. When
# the real `omarchy update` flow calls `omarchy-update-aur-pkgs` (by bare
# name), the shadow PATH prepended by `omarchy-omashield update` makes THIS
# command win.
#
# Instead of blindly upgrading every AUR package (the stock behaviour) it only
# installs the AUR packages the user preselected in the interactive picker and
# that survived the aur-scan + yay-guard review. The native yay hooks run
# again here as a second layer of protection.

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
source "$(dirname "$SELF")/lib-state.sh"
source "$(dirname "$SELF")/ensure-tools.sh"

# Never let a hiccup here abort the whole omarchy update; this stage is what
# replaced the stock AUR stage, so a failure should be loud but contained.
# (The caller's ERR trap in omarchy-update will still surface problems.)

if [[ -f $PENDING_AUR_FILE ]]; then
  mapfile -t selected < "$PENDING_AUR_FILE"
else
  selected=()
fi

if ((${#selected[@]} == 0)); then
  echo -e "\e[33m\nOmaShield: no AUR package updates were selected — skipping the AUR stage.\e[0m"
  echo
  exit 0
fi

# Fail closed: only install what the gate reviewed. If the pending set changed
# after the review (hand edit, concurrent run), skip loudly instead of
# installing unreviewed packages. No prompts here — this stage must stay safe
# in unattended runs.
if [[ -f $SCANNED_AUR_FILE ]]; then
  if ! diff -q "$SCANNED_AUR_FILE" "$PENDING_AUR_FILE" >/dev/null 2>&1; then
    echo -e "\e[1;31m\nOmaShield: the pending AUR set changed after review — skipping the AUR stage.\e[0m"
    echo -e "\e[33mRe-run the guarded update to review the current selection.\e[0m"
    echo
    exit 0
  fi
else
  echo -e "\e[1;31m\nOmaShield: no review stamp for the pending AUR set — skipping the AUR stage.\e[0m"
  echo -e "\e[33mRe-run the guarded update to review the current selection.\e[0m"
  echo
  exit 0
fi

if ! command -v aur-scan >/dev/null 2>&1; then
  ensure_tools || exit 0
fi

echo -e "\e[32m\nUpdate selected AUR packages\e[0m"
# Same flags the stock flow used (--cleanafter, its ignore list) plus
# --needed so already-current packages are left alone.
stock_ignore=$(stock_aur_ignore)
if [[ -n $stock_ignore ]]; then
  yay -S --noconfirm --needed --cleanafter --ignore="$stock_ignore" "${selected[@]}"
else
  yay -S --noconfirm --needed --cleanafter "${selected[@]}"
fi
echo
