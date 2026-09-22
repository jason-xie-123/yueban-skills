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

# Runs "$@"; on failure, prints "FAILED: <context>" to stderr and returns 1
# (caller does `run_step "..." cmd... || return 2`). On success, returns 0.
# Centralizes the "check the mutating command's exit code, don't silently
# swallow a failure and report success anyway" pattern used throughout.
run_step() {
  local context="$1"; shift
  "$@" && return 0
  echo "FAILED: ${context}" >&2
  return 1
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

  # The superproject itself gets the same divergence check submodules get
  # below — otherwise a fast-forward here could silently diverge (or worse,
  # leave an unresolved conflict) instead of stopping. This reuses the fetch
  # that sm_ahead_behind already does; the actual pull further down then
  # fast-forwards directly off that already-fetched ref instead of calling
  # `git pull` (which would fetch a second time and depend on the user's
  # local pull.rebase/merge config instead of a deterministic ff-only).
  local super_branch
  super_branch="$(sm_branch ".")"
  if [ -z "$super_branch" ]; then
    echo "BLOCKED: superproject is in detached HEAD. Resolve manually first (checkout the intended branch)." >&2
    return 2
  fi
  local super_ab super_ahead super_behind
  if ! super_ab="$(sm_ahead_behind "." "$super_branch")"; then
    echo "BLOCKED: superproject branch '$super_branch' has no origin/$super_branch to compare against." >&2
    return 2
  fi
  super_ahead="$(echo "$super_ab" | awk '{print $1}')"
  super_behind="$(echo "$super_ab" | awk '{print $2}')"
  if [ "$super_ahead" -gt 0 ] && [ "$super_behind" -gt 0 ]; then
    echo "BLOCKED: superproject ($super_branch) has diverged from origin/$super_branch (ahead $super_ahead, behind $super_behind). Merge/rebase decision needed — resolve by hand." >&2
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
  if [ "$super_behind" -gt 0 ]; then
    run_step "superproject fast-forward of $super_branch to origin/$super_branch failed unexpectedly (see output above — e.g. a conflict). Nothing else was touched; resolve the superproject by hand before re-running." \
      git merge --ff-only "origin/$super_branch" || return 2
  else
    echo "Already up to date."
  fi

  local i
  for i in "${!paths[@]}"; do
    path="${paths[$i]}"; branch="${branches[$i]}"
    echo "-- $path: fast-forwarding $branch to origin/$branch --"
    run_step "$path: fast-forward of $branch failed unexpectedly. The superproject was already pulled; resolve $path by hand, then re-run." \
      git -C "$path" merge --ff-only "origin/$branch" || return 2
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
  local super_ahead super_behind

  # Same divergence check cmd_pull does for the superproject, so a plain
  # `git push` failing on non-fast-forward isn't the first time we notice
  # the superproject is behind — we report it alongside the other BLOCKED
  # items instead of failing mid-push after submodules already went out.
  local super_branch super_ab
  super_branch="$(sm_branch ".")"
  if [ -z "$super_branch" ]; then
    echo "BLOCKED: superproject is in detached HEAD. Resolve manually first (checkout the intended branch)." >&2
    return 2
  fi
  if super_ab="$(sm_ahead_behind "." "$super_branch")"; then
    super_ahead="$(echo "$super_ab" | awk '{print $1}')"
    super_behind="$(echo "$super_ab" | awk '{print $2}')"
    if [ "$super_behind" -gt 0 ]; then
      echo "BLOCKED: superproject ($super_branch) is behind origin/$super_branch by $super_behind commit(s) (ahead $super_ahead). Pull first — this tool never force-pushes." >&2
      return 2
    fi
  else
    echo "BLOCKED: superproject branch '$super_branch' has no origin/$super_branch — first push needs to be done by hand (git push -u origin $super_branch)." >&2
    return 2
  fi

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
  local -a pushed_paths=()
  for i in "${!push_paths[@]}"; do
    path="${push_paths[$i]}"; branch="${push_branches[$i]}"
    echo "-- pushing $path ($branch) --"
    run_step "$path: push to origin/$branch failed. Stopping — already pushed: ${pushed_paths[*]:-<none>}. The superproject was NOT pushed. Resolve $path by hand, then re-run." \
      git -C "$path" push origin "HEAD:refs/heads/$branch" || return 2
    pushed_paths+=("$path")
  done

  if [ "$super_ahead" -gt 0 ]; then
    echo "-- pushing superproject --"
    run_step "superproject push failed. All submodule commits above were already pushed to their own remotes; resolve the superproject by hand, then re-run (the submodule pushes will just report 'up to date')." \
      git push || return 2
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
