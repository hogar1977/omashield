#!/bin/bash
# OmaShield — update picker: preselect repo/AUR/mise updates, scan the AUR
# picks, greenlight, save selections for the shadow stages (nothing installed here).

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib-state.sh"
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib-gate.sh"

clear_pending() {
  : > "$PENDING_AUR_FILE"
  : > "$PENDING_REPO_FILE"
  : > "$SCANNED_AUR_FILE"
  : > "$SEEN_REPO_FILE"
  : > "$PENDING_MISE_FILE"
}

# Persist a repo-only outcome when the AUR stage is deferred.
save_repo_only() {
  : > "$PENDING_AUR_FILE"
  : > "$SCANNED_AUR_FILE"
  printf '%s\n' "$@" | sed '/^$/d' | sort -u > "$PENDING_REPO_FILE"
  local n
  n=$(wc -l < "$PENDING_REPO_FILE" 2>/dev/null | tr -d ' ')
  echo -e "\e[32mRepo selection saved — the update phase will install ${n:-0} repo package(s), AUR deferred.\e[0m"
}

# Outdated mise tool names, one per line.
mise_outdated() {
  local tools_json
  tools_json=$(MISE_MINIMUM_RELEASE_AGE=0 mise outdated --json 2>/dev/null) || tools_json="{}"
  python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print("\n".join(sorted(d.keys())) if isinstance(d,dict) else [])
' <<< "$tools_json"
}

# Preselect outdated mise tools. Saves immediately (even when empty), so all
# later exit paths keep the mise choice; cancelling aborts the whole update.
pick_mise() {
  if (($# == 0)); then
    : > "$PENDING_MISE_FILE"
    echo -e "\e[32mmise tools are up to date.\e[0m"
    return 0
  fi

  local names=("$@")
  echo -e "\e[1;36m\nmise tools — ${#names[@]} outdated (preselected)\e[0m"
  local sel_args=() n
  for n in "${names[@]}"; do sel_args+=(--selected="$n"); done
  local kept rc
  kept=$(printf '%s\n' "${names[@]}" | gum choose \
    --height 10 \
    --no-limit \
    "${sel_args[@]}" \
    --header "mise — deselect the ones to defer")
  rc=$?
  if ((rc != 0)); then
    echo -e "\e[33mSelection cancelled — nothing will be changed.\e[0m"
    return 1
  fi
  printf '%s\n' "$kept" | sed '/^$/d' | sort -u > "$PENDING_MISE_FILE"
  local c
  c=$(wc -l < "$PENDING_MISE_FILE" 2>/dev/null | tr -d ' ')
  echo -e "\e[32m${c:-0} mise tool(s) will update.\e[0m"
  return 0
}

# Warn when the repo databases are stale (the picker cannot refresh them
# itself; the AUR list below is still live via RPC).
warn_sync_age() {
  local newest=0 f mtime now age
  for f in /var/lib/pacman/sync/*.db; do
    [[ -f $f && -r $f ]] || continue
    mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
    ((mtime > newest)) && newest=$mtime
  done
  ((newest == 0)) && return 0
  now=$(date +%s)
  age=$(( (now - newest) / 3600 ))
  if ((age >= 24)); then
    echo -e "\e[33mNote: the repo package databases are ~$((age / 24)) day(s) old — very recent repo updates may not be listed below (the AUR list is live). The update phase syncs before installing.\e[0m"
  fi
}

# guard_update: 0 = update may proceed (empty pending files = defer all),
# 1 = could not run (tools missing, picker cancelled) — caller must stop.
guard_update() {
  require_tools || return 1

  warn_sync_age

  # Pending updates: repo from the synced db, AUR from the AUR RPC.
  local repo=() aur=() p
  while IFS= read -r p; do
    [[ -n $p ]] && repo+=("$p")
  done < <(list_repo_updates)
  while IFS= read -r p; do
    [[ -n $p ]] && aur+=("$p")
  done < <(list_aur_updates)

  local mise=() m
  while IFS= read -r m; do [[ -n $m ]] && mise+=("$m"); done < <(mise_outdated)

  if ((${#repo[@]} == 0 && ${#aur[@]} == 0 && ${#mise[@]} == 0)); then
    echo -e "\e[32mNo updates are pending right now.\e[0m"
    clear_pending
    return 0
  fi

  # Remember everything the picker is about to offer: the shadow system stage
  # compares this against the post-sync pending list to report repo updates
  # that surfaced only after the selection was made.
  printf '%s\n' "${repo[@]}" | sed '/^$/d' | sort -u > "$SEEN_REPO_FILE"

  local combined=()
  declare -A seen_pkg=()
  for p in "${repo[@]}" "${aur[@]}"; do
    [[ -n $p && -z ${seen_pkg[$p]:-} ]] || continue
    seen_pkg[$p]=1
    combined+=("$p")
  done
  local n_all=${#combined[@]}

  local kept="" rc=0
  if ((n_all == 0)); then
    echo -e "\e[32mNo repo/AUR updates pending.\e[0m"
  else
    echo -e "\e[1;36m\nInteractive update selection — $n_all pending\e[0m"
    echo -e "(${#repo[@]} repo, ${#aur[@]} AUR)"
    echo -e "All updates are \e[1mpreselected\e[0m. Press \e[1mTab\e[0m (or Space/x) to deselect"
    echo -e "(defer) a package, then \e[1mEnter\e[0m to continue. Anything that depends"
    echo -e "on a deferred package is deferred too."
    echo

    # --no-limit makes this a true multi-select list; each entry starts selected.
    local sel_args=()
    for p in "${combined[@]}"; do sel_args+=(--selected="$p"); done
    kept=$(printf '%s\n' "${combined[@]}" | gum choose \
      --height 18 \
      --no-limit \
      "${sel_args[@]}" \
      --header "Updates — deselect the ones to defer (all others update)")
    rc=$?
    if ((rc != 0)); then
      echo -e "\e[33mSelection cancelled — nothing will be changed.\e[0m"
      return 1
    fi
  fi

  declare -A kept_set=()
  local k
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    kept_set[$k]=1
  done <<< "$kept"

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

  # Cascade: also defer kept packages depending on a deferred one.
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

  # Split kept into repo vs AUR (either list wins AUR = stricter).
  local kept_repo=() kept_aur=() kept_arr=()
  declare -A aur_set=()
  for p in "${aur[@]}"; do aur_set[$p]=1; done
  for k in "${!kept_set[@]}"; do
    [[ -n $k ]] || continue
    kept_arr+=("$k")
    if [[ -n ${aur_set[$k]:-} ]]; then kept_aur+=("$k"); else kept_repo+=("$k"); fi
  done

  if ((${#kept_arr[@]} == 0 && ${#mise[@]} == 0)); then
    echo -e "\e[1;33m\nEvery update is deferred — nothing will be changed.\e[0m"
    clear_pending
    return 0
  fi

  if ((${#kept_arr[@]} > 0 || ${#deferred[@]} > 0)); then
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
  fi

  pick_mise "${mise[@]}" || return 1

  # Scan only the AUR survivors; repo-only selections skip the scanners.
  if ((${#kept_aur[@]})); then
    require_tools || return 1

    if ! gate_scan "${kept_aur[@]}"; then
      echo
      if gum confirm --default=false \
        --affirmative="Force install anyway" \
        --negative="Skip the AUR stage" \
        "High/critical findings were reported above. What should OmaShield do?"; then
        echo -e "\e[33mForcing the risky AUR update(s) — your explicit choice.\e[0m"
      else
        echo -e "\e[1;31mAUR stage skipped — the repo selection below still updates.\e[0m"
        save_repo_only "${kept_repo[@]}"
        return 0
      fi
    fi

    echo
    if ! gum confirm --default=true \
      --affirmative="Proceed with ${#kept_aur[@]} AUR update(s)" \
      --negative="Abort — skip the AUR stage" \
      "Greenlight the scanned AUR updates? The rest of the omarchy update continues after this."; then
      echo -e "\e[1;31mAUR stage skipped by you — the repo selection below still updates.\e[0m"
      save_repo_only "${kept_repo[@]}"
      return 0
    fi
  else
    echo -e "\e[32mNo AUR packages in this update — aur-scan and yay-guard are not needed.\e[0m"
  fi

  printf '%s\n' "${kept_repo[@]:-}" | sed '/^$/d' | sort -u > "$PENDING_REPO_FILE"
  printf '%s\n' "${kept_aur[@]:-}"  | sed '/^$/d' | sort -u > "$PENDING_AUR_FILE"
  # Stamp the reviewed set; the shadow refuses anything not on this list.
  cp "$PENDING_AUR_FILE" "$SCANNED_AUR_FILE"
  echo -e "\e[32m\nSelection saved — the update phase will install ${#kept_arr[@]} package(s).\e[0m"
  return 0
}

# Run only when invoked directly.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  guard_update
fi