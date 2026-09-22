#!/usr/bin/env bash
# submodule-safe-sync: keep submodules on their tracked branch across pull/push,
# instead of the git-default "checkout by recorded SHA" behavior that detaches
# HEAD. See ../SKILL.md for the full rationale and workflow this script serves.
#
# Usage:
#   sync.sh status
#   sync.sh pull
#   sync.sh push [--dry-run]
#
# Exit codes:
#   0 = clean / completed
#   1 = usage error
#   2 = at least one submodule (or the superproject) is blocked; nothing was
#       changed for pull, and nothing was pushed for push.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || exit 1

# --- helpers -----------------------------------------------------------

list_submodules() {
  # Active submodules only: paths under deprecated/ are intentionally out of
  # scope (see SKILL.md) — they don't need to stay in lockstep across machines.
  git config -f .gitmodules --get-regexp '\.path$' 2>/dev/null \
    | awk '{print $2}' \
    | grep -v '^deprecated/'
}

sm_branch() {
  git -C "$1" symbolic-ref --short -q HEAD || true
}

sm_is_dirty() {
  [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]
}

sm_recorded_sha() {
  # What the superproject's HEAD currently records for this submodule path.
  git rev-parse -q --verify "HEAD:$1" 2>/dev/null || true
}

sm_head_sha() {
  git -C "$1" rev-parse HEAD 2>/dev/null || true
}

# ahead/behind counts of local branch vs its origin/<branch>, after a fetch.
# Prints "AHEAD BEHIND" or nothing if origin/<branch> doesn't exist yet.
sm_ahead_behind() {
  local path="$1" branch="$2"
  git -C "$path" fetch --quiet origin "$branch" 2>/dev/null || true
  if ! git -C "$path" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
    return 1
  fi
  git -C "$path" rev-list --left-right --count "origin/$branch...HEAD" 2>/dev/null | awk '{print $2, $1}'
}

# --- status --------------------------------------------------------------

cmd_status() {
  echo "== superproject =="
  git status --short --branch | sed 's/^/  /'
  echo
  echo "== submodules =="
  local path branch dirty rec head ab ahead behind
  while IFS= read -r path; do
    [ -d "$path" ] || { echo "  $path: MISSING (not checked out)"; continue; }
    branch="$(sm_branch "$path")"
    dirty="clean"; sm_is_dirty "$path" && dirty="DIRTY"
    rec="$(sm_recorded_sha "$path")"
    head="$(sm_head_sha "$path")"
    printf '  %s: branch=%s %s' "$path" "${branch:-<DETACHED>}" "$dirty"
    if [ -n "$branch" ]; then
      if ab="$(sm_ahead_behind "$path" "$branch")"; then
        ahead="$(echo "$ab" | awk '{print $1}')"
        behind="$(echo "$ab" | awk '{print $2}')"
        printf ' ahead=%s behind=%s' "$ahead" "$behind"
      else
        printf ' (no origin/%s tracked yet)' "$branch"
      fi
    fi
    if [ "$rec" != "$head" ]; then
      printf ' [recorded-by-superproject=%s current=%s]' "${rec:0:8}" "${head:0:8}"
    fi
    echo
  done < <(list_submodules)
}

# --- pull ------------------------------------------------------------------

cmd_pull() {
  # --ignore-submodules=all: a submodule pointer that's simply ahead of what
  # the superproject last recorded is the normal, expected state this whole
  # flow produces (see SKILL.md) — not "uncommitted changes". Each
  # submodule's own dirty/detached/diverged state is checked separately below.
  if [ -n "$(git status --porcelain --ignore-submodules=all 2>/dev/null)" ]; then
    echo "BLOCKED: superproject working tree has uncommitted changes outside submodules. Commit or stash first." >&2
    return 2
  fi

  local -a paths=() branches=()
  local path branch
  local blocked=0

  while IFS= read -r path; do
    [ -d "$path" ] || { echo "BLOCKED: $path is not checked out (run a plain git submodule update --init once, outside this flow)." >&2; blocked=1; continue; }
    branch="$(sm_branch "$path")"
    if [ -z "$branch" ]; then
      echo "BLOCKED: $path is already in detached HEAD. Resolve manually first (checkout the intended branch) — this tool will not guess which branch you meant." >&2
      blocked=1
      continue
    fi
    if sm_is_dirty "$path"; then
      echo "BLOCKED: $path has uncommitted changes. Commit or stash inside the submodule first." >&2
      blocked=1
      continue
    fi
    local ab ahead behind
    if ! ab="$(sm_ahead_behind "$path" "$branch")"; then
      echo "BLOCKED: $path branch '$branch' has no origin/$branch to compare against." >&2
      blocked=1
      continue
    fi
    ahead="$(echo "$ab" | awk '{print $1}')"
    behind="$(echo "$ab" | awk '{print $2}')"
    if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
      echo "BLOCKED: $path ($branch) has diverged from origin/$branch (ahead $ahead, behind $behind). Merge/rebase decision needed — resolve by hand." >&2
      blocked=1
      continue
    fi
    paths+=("$path")
    branches+=("$branch")
  done < <(list_submodules)

  if [ "$blocked" -ne 0 ]; then
    echo
    echo "Nothing changed. Fix the BLOCKED items above and re-run." >&2
    return 2
  fi

  echo "Pulling superproject (top-level refs only, submodules handled separately)..."
  git pull --no-recurse-submodules

  local i
  for i in "${!paths[@]}"; do
    path="${paths[$i]}"; branch="${branches[$i]}"
    echo "-- $path: fast-forwarding $branch to origin/$branch --"
    git -C "$path" merge --ff-only "origin/$branch"
  done

  echo
  echo "Done. Every submodule stayed on its branch (no detached HEAD)."
  cmd_status
}

# --- push ------------------------------------------------------------------

cmd_push() {
  local dry_run=0
  [ "${1:-}" = "--dry-run" ] && dry_run=1

  local -a push_paths=() push_branches=()
  local path branch
  local blocked=0
  local super_ahead

  while IFS= read -r path; do
    [ -d "$path" ] || { echo "BLOCKED: $path is not checked out." >&2; blocked=1; continue; }
    branch="$(sm_branch "$path")"
    if [ -z "$branch" ]; then
      echo "BLOCKED: $path is in detached HEAD — its commits aren't on any branch, so they can't be safely pushed. Resolve manually." >&2
      blocked=1
      continue
    fi
    if sm_is_dirty "$path"; then
      echo "BLOCKED: $path has uncommitted changes. Commit inside the submodule first." >&2
      blocked=1
      continue
    fi
    local ab ahead behind
    if ! ab="$(sm_ahead_behind "$path" "$branch")"; then
      echo "BLOCKED: $path branch '$branch' has no origin/$branch — first push needs to be done by hand (git -C $path push -u origin $branch)." >&2
      blocked=1
      continue
    fi
    ahead="$(echo "$ab" | awk '{print $1}')"
    behind="$(echo "$ab" | awk '{print $2}')"
    if [ "$behind" -gt 0 ]; then
      echo "BLOCKED: $path ($branch) is behind origin/$branch by $behind commit(s) (ahead $ahead). Pull first — this tool never force-pushes." >&2
      blocked=1
      continue
    fi
    if [ "$ahead" -gt 0 ]; then
      echo "PLAN: $path — push $ahead commit(s) to origin/$branch"
      push_paths+=("$path")
      push_branches+=("$branch")
    else
      echo "PLAN: $path — up to date, nothing to push"
    fi
  done < <(list_submodules)

  if [ "$blocked" -ne 0 ]; then
    echo
    echo "Nothing pushed. Fix the BLOCKED items above and re-run." >&2
    return 2
  fi

  super_ahead="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
  if [ "$super_ahead" -gt 0 ]; then
    echo "PLAN: superproject — push $super_ahead commit(s)"
  else
    echo "PLAN: superproject — up to date, nothing to push"
  fi

  if [ "$dry_run" -eq 1 ]; then
    echo
    echo "(dry run — nothing pushed)"
    return 0
  fi

  local i
  for i in "${!push_paths[@]}"; do
    path="${push_paths[$i]}"; branch="${push_branches[$i]}"
    echo "-- pushing $path ($branch) --"
    git -C "$path" push origin "HEAD:refs/heads/$branch"
  done

  if [ "$super_ahead" -gt 0 ]; then
    echo "-- pushing superproject --"
    git push
  fi

  echo
  echo "Done. Submodule commits were pushed before the superproject, so its recorded pointers are never ahead of what's on the remote."
}

# --- main --------------------------------------------------------------

case "${1:-}" in
  status) cmd_status ;;
  pull) cmd_pull ;;
  push) shift; cmd_push "${1:-}" ;;
  *)
    echo "Usage: $0 {status|pull|push [--dry-run]}" >&2
    exit 1
    ;;
esac
