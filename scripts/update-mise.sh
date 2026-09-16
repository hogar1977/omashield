#!/bin/bash
# OmaShield — shadow for omarchy-update-mise: upgrades only preselected tools.

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
source "$(dirname "$SELF")/lib-state.sh"

selected=()
if [[ -f $PENDING_MISE_FILE ]]; then
  mapfile -t selected < <(grep -v '^$' "$PENDING_MISE_FILE" 2>/dev/null)
fi

if ((${#selected[@]} == 0)); then
  echo -e "\e[33m\nOmaShield: no mise tools were selected — skipping the mise stage.\e[0m"
  echo
  exit 0
fi

echo -e "\e[32m\nUpdate selected mise tools\e[0m"
# Same no-cooldown semantics as stock; named tools only.
MISE_MINIMUM_RELEASE_AGE=0 mise upgrade "${selected[@]}"
rc=$?
echo
exit $rc
