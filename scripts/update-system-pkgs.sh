#!/bin/bash
#
# OmaShield — drop-in replacement for omarchy-update-system-pkgs.
#
# The first-ON wiring symlinks this file from a PATH-shadow directory. When the real
# `omarchy update` flow calls `omarchy-update-system-pkgs` (by bare name) via
# the PATH prepended by `omarchy-omashield update`, THIS command wins.
#
# Instead of blindly upgrading every repo package it only installs the repo
# packages the user preselected in the interactive picker. The databases were
# already refreshed by the picker, so installing by exact name avoids a
# "partial -Syu" (the requested set is still every package the user saw).

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
source "$(dirname "$SELF")/lib-state.sh"

if [[ -f $PENDING_REPO_FILE ]]; then
  mapfile -t selected < "$PENDING_REPO_FILE"
else
  selected=()
fi

if ((${#selected[@]} == 0)); then
  echo -e "\e[33m\nOmaShield: no repo packages were selected — skipping the system stage.\e[0m"
  echo
  exit 0
fi

echo -e "\e[32m\nUpdate selected system packages\e[0m"
# Mirror the stock stage's flags and env so pacman hooks and Omarchy's
# unowned-file handling see the same world. Omarchy-packaged paths win there.
sudo env LC_ALL=C OMARCHY_UPDATE_PACMAN=1 pacman -S --noconfirm --needed \
  --overwrite '/usr/share/omarchy/*' "${selected[@]}"
echo

# Anything that failed is an update problem, not a shield problem: let the
# caller's ERR trap report it exactly like the stock stage would.
if ((PIPESTATUS[0] != 0)); then
  exit 1
fi
exit 0