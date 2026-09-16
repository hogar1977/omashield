#!/bin/bash
# OmaShield — shadow for omarchy-update-aur-pkgs: installs only the reviewed
# preselection (native yay hooks re-check as a second layer).

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
source "$(dirname "$SELF")/lib-state.sh"
source "$(dirname "$SELF")/lib-gate.sh"

# A hiccup here must stay loud but contained, never aborting the whole update.

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

# Fail closed: install only what the gate reviewed; skip loudly otherwise.
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

# The tools are re-checked read-only: if they vanished mid-run the shield
# switches itself OFF and this stage is skipped (never reinstalled from here).
if ! gate_tools_ready; then
  echo
  tools_missing_notice
  echo
  exit 0
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
