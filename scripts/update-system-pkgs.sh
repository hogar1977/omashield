#!/bin/bash
# OmaShield — shadow for omarchy-update-system-pkgs: installs only the
# preselected repo set. Never handles elevation itself; yay escalates.

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
# The picker listed from the last-synced databases, so sync first.
yay -Sy --noconfirm \
  || echo -e "\e[33mOmaShield: database refresh failed — installing from the current databases.\e[0m"

# Report repo updates that surfaced only after the selection: they stay
# uninstalled in this run, so the user knows to re-run Update.
if [[ -f $SEEN_REPO_FILE ]]; then
  declare -A sel_set=() seen_set=()
  local s c
  for s in "${selected[@]}"; do [[ -n $s ]] && sel_set[$s]=1; done
  while IFS= read -r c; do [[ -n $c ]] && seen_set[$c]=1; done < "$SEEN_REPO_FILE"
  local surfaced=()
  while IFS= read -r c; do
    if [[ -n $c && -z ${sel_set[$c]:-} && -z ${seen_set[$c]:-} ]]; then
      surfaced+=("$c")
    fi
  done < <(pacman -Qu 2>/dev/null | awk '{print $1}' | sort -u)
  if ((${#surfaced[@]})); then
    echo -e "\e[33mNote: ${#surfaced[@]} further repo update(s) appeared after your selection and will stay uninstalled here: ${surfaced[*]}\e[0m"
    echo -e "\e[33mRe-run Update to review them.\e[0m"
  fi
fi

env LC_ALL=C OMARCHY_UPDATE_PACMAN=1 yay -S --noconfirm --needed \
  --overwrite '/usr/share/omarchy/*' "${selected[@]}"
rc=$?
echo

# Propagate failures so the caller's ERR trap reports them like stock.
exit $rc