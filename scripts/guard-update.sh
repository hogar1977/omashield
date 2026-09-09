#!/bin/bash
#
# OmaShield — interactive update picker (repo + AUR).
#
# This replaces omarchy's silent "upgrade everything" behaviour with a
# reviewable interaction:
#
#   1. Every pending repo AND AUR update is listed, all preselected.
#   2. You deselect the ones you want to defer (Space / Enter to confirm).
#   3. Any package that depends on a deferred one is deferred too.
#   4. If AUR packages survive, aur-scan AND yay-guard review them. When the
#      selection is repo-only, the scanners are skipped (nothing to audit).
#   5. Only after you greenlight the reports is the selection saved.
#
# Nothing is installed or upgraded from here — the saved lists are consumed by
# the shadowed `omarchy-update-system-pkgs` and `omarchy-update-aur-pkgs`
# during the real omarchy update.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib-state.sh"
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib-gate.sh"
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/ensure-tools.sh"

clear_pending() {
  : > "$PENDING_AUR_FILE"
  : > "$PENDING_REPO_FILE"
  : > "$SCANNED_AUR_FILE"
}

# guard_update ()
#   returns 0 when the system update may proceed (the pending files may be
#           empty meaning "defer every package")
#   returns 1 when the flow could not run at all (tools refused)
guard_update() {
  ensure_tools || return 1

  # The repo upgrade list must see the versions pacman will install, so
  # refresh the databases before listing (sudo asked once, here, in the
  # interactive terminal). Best-effort: a stale db still yields a list.
  if sudo -v 2>/dev/null; then
    echo -e "\e[1;36mRefreshing package databases…\e[0m"
    sudo -n pacman -Sy >/dev/null 2>&1 \
      || echo -e "\e[33mCould not refresh the mirror databases — showing the current list.\e[0m"
  else
    echo -e "\e[33mNo sudo available — showing the current list.\e[0m"
  fi

  # What can be updated right now? Repo upgrades come from the synced db,
  # AUR upgrades from the AUR RPC. Both print "name old-ver new-ver".
  local repo_aur_restored
  local repo=() aur=() p
  while IFS= read -r p; do
    [[ -n $p ]] && repo+=("$p")
  done < <(pacman -Qu 2>/dev/null | awk '{print $1}')
  while IFS= read -r p; do
    [[ -n $p ]] && aur+=("$p")
  done < <(yay -Qua 2>/dev/null | awk '{print $1}')
  # The stock omarchy flow already ignores these in the AUR stage; keep that.
  # The list is parsed from the stock script so we never drift out of sync.
  local stock_ignore ignore_list=()
  stock_ignore=$(stock_aur_ignore)
  if [[ -n $stock_ignore ]]; then
    IFS=',' read -ra ignore_list <<< "$stock_ignore"
  fi
  for p in "${ignore_list[@]}"; do
    [[ -n $p ]] || continue
    local filtered=()
    for a in "${aur[@]}"; do [[ $a != "$p" ]] && filtered+=("$a"); done
    aur=("${filtered[@]}")
  done

  if ((${#repo[@]} == 0 && ${#aur[@]} == 0)); then
    echo -e "\e[32mNo updates are pending right now.\e[0m"
    clear_pending
    return 0
  fi

  local n_all=$(( ${#repo[@]} + ${#aur[@]} ))
  local combined=("${repo[@]}" "${aur[@]}")

  echo -e "\e[1;36m\nInteractive update selection — $n_all pending\e[0m"
  echo -e "(${#repo[@]} repo, ${#aur[@]} AUR)"
  echo -e "All updates are \e[1mpreselected\e[0m. Press \e[1mSpace\e[0m to deselect"
  echo -e "(defer) a package, then \e[1mEnter\e[0m to continue. Anything that depends"
  echo -e "on a deferred package is deferred too."
  echo

  local kept
  kept=$(printf '%s\n' "${combined[@]}" | gum choose \
    --height 18 \
    --selected='*' \
    --header "Updates — deselect the ones to defer (all others update)" \
    --input-delimiter=$'\n' \
    --output-delimiter=$'\n' 2>/dev/null)

  declare -A kept_set=()
  local k
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    kept_set[$k]=1
  done <<< "$kept"

  # Everything not kept is deferred.
  declare -A deferred_set=()
  local deferred=()
  for p in "${combined[@]}"; do
    if [[ -z ${kept_set[$p]:-} ]]; then
      deferred_set[$p]=1
      deferred+=("$p")
    fi
  done

  if ((${#deferred[@]})); then
    echo
    echo -e "\e[33mYou deferred (${#deferred[@]}): ${deferred[*]}\e[0m"
  fi

  # Cascade: if a deferred package is depended on by a kept one, defer that
  # one too. pactree -r lists everything installed that depends on a package
  # (directly or transitively).
  local changed=1 round=0 d r ndeps
  declare -a newdefer=()
  while ((changed)) && ((round < 12)); do
    changed=0
    ((round++))
    newdefer=()
    for d in "${deferred[@]}"; do
      ndeps=$(pactree -ur "$d" 2>/dev/null || true)
      [[ -n $ndeps ]] || continue
      while IFS= read -r r; do
        [[ -n $r ]] || continue
        if [[ -n ${kept_set[$r]:-} ]]; then
          unset 'kept_set[$r]'
          if [[ -z ${deferred_set[$r]:-} ]]; then
            deferred_set[$r]=1
            newdefer+=("$r")
            echo -e "\e[33m→ Deferred '$r' because it depends on '$d'.\e[0m"
          fi
          changed=1
        fi
      done <<< "$ndeps"
    done
    deferred+=("${newdefer[@]}")
  done

  # Final split: kept → repo vs AUR (a package present in both lists counts
  # as AUR, which is the stricter membership).
  local kept_repo=() kept_aur=() kept_arr=()
  declare -A aur_set=()
  for p in "${aur[@]}"; do aur_set[$p]=1; done
  for k in "${!kept_set[@]}"; do
    [[ -n $k ]] || continue
    kept_arr+=("$k")
    if [[ -n ${aur_set[$k]:-} ]]; then kept_aur+=("$k"); else kept_repo+=("$k"); fi
  done

  if ((${#kept_arr[@]} == 0)); then
    echo -e "\e[1;33m\nEvery update is deferred — nothing will be changed.\e[0m"
    clear_pending
    return 0
  fi

  echo
  echo -e "\e[1;36mFinal update set (${#kept_arr[@]}):\e[0m"
  if ((${#kept_repo[@]})); then
    echo -e "  repo (${#kept_repo[@]}):"
    printf '    \e[32m%s\e[0m\n' "${kept_repo[@]}" | sort
  fi
  if ((${#kept_aur[@]})); then
    echo -e "  AUR (${#kept_aur[@]}):"
    printf '    \e[36m%s\e[0m\n' "${kept_aur[@]}" | sort
  fi
  if ((${#deferred[@]})); then
    echo
    echo -e "\e[33mDeferred (${#deferred[@]}):\e[0m"
    printf '   %s\n' "${deferred[@]}" | sort -u
  fi
  echo

  # Scan only what actually comes from the AUR. A repo-only selection has
  # nothing for aur-scan/yay-guard to audit, so those runs are skipped.
  if ((${#kept_aur[@]})); then
    if ! gate_tools_ready; then ensure_tools || return 1; fi

    if ! gate_scan "${kept_aur[@]}"; then
      echo
      if gum confirm --default=false \
        --affirmative="Force install anyway" \
        --negative="Skip the AUR stage" \
        "High/critical findings were reported above. What should OmaShield do?"; then
        echo -e "\e[33mForcing the risky AUR update(s) — your explicit choice.\e[0m"
      else
        echo -e "\e[1;31mAUR stage skipped — nothing from the AUR was installed.\e[0m"
        : > "$PENDING_AUR_FILE"
        : > "$SCANNED_AUR_FILE"
        return 0
      fi
    fi

    echo
    if ! gum confirm --default=true \
      --affirmative="Proceed with ${#kept_aur[@]} AUR update(s)" \
      --negative="Abort — skip the AUR stage" \
      "Greenlight the scanned AUR updates? The rest of the omarchy update continues after this."; then
      echo -e "\e[1;31mAborted by you — the AUR stage is skipped.\e[0m"
      : > "$PENDING_AUR_FILE"
      : > "$SCANNED_AUR_FILE"
      return 0
    fi
  else
    echo -e "\e[32mNo AUR packages in this update — aur-scan and yay-guard are not needed.\e[0m"
  fi

  printf '%s\n' "${kept_repo[@]:-}" | sed '/^$/d' | sort -u > "$PENDING_REPO_FILE"
  printf '%s\n' "${kept_aur[@]:-}"  | sed '/^$/d' | sort -u > "$PENDING_AUR_FILE"
  # Stamp the reviewed AUR set: the shadow stage refuses to install anything
  # that is not on this list (it changed after review).
  cp "$PENDING_AUR_FILE" "$SCANNED_AUR_FILE"
  echo -e "\e[32m\nSelection saved — the update phase will install ${#kept_arr[@]} package(s).\e[0m"
  return 0
}

# Run only when invoked directly.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  guard_update
fi