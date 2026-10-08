#!/usr/bin/env bash
# yueban-git-feature-branch-flow: start/sync/finish a same-named feature branch
# across the superproject and every actively-maintained submodule. The base
# branch (what the feature branches off of — whatever the project uses, selectable)
# is chosen at 'start' time and remembered per (repo, change-id) via git
# config, so 'sync'/'finish' don't need it repeated. See ../SKILL.md for the
# full rationale and workflow this script serves.
#
# Usage:
#   flow.sh branches
#   flow.sh start   <change-id> <base-branch>
#   flow.sh pending <change-id>
#   flow.sh sync    <change-id>
#   flow.sh finish  <change-id> [--base <branch>] [--cleanup]
#   flow.sh status
#
# Exit codes:
#   0 = clean / completed
#   1 = usage error
#   2 = at least one repo is blocked. Preflight problems change nothing anywhere;
#       a git command failing midway stops there and lists the repos already done.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$REPO_ROOT" || exit 1

# Run inside a submodule, every command would treat that one submodule as the
# whole project. A repo that has its own .gitmodules is a superproject even if
# it is nested in another one.
SUPER_ROOT="$(git rev-parse --show-superproject-working-tree 2>/dev/null)"
if [ -n "$SUPER_ROOT" ] && [ ! -f .gitmodules ]; then
  echo "BLOCKED: this is a submodule ($REPO_ROOT). Run this from its superproject: $SUPER_ROOT" >&2
  exit 2
fi

# Every git call that moves HEAD goes through this: with submodule.recurse=true
# (user or repo config), checkout/merge in the superproject would also check
# out each submodule at its recorded commit, i.e. detach its HEAD.
gitnr() {
  git -c submodule.recurse=false "$@"
}

# --- helpers -----------------------------------------------------------

list_submodules() {
  # Active submodules only: paths under deprecated/ (frozen/historical
  # modules) are intentionally out of scope — see SKILL.md. -z output is
  # "<key>\n<value>\0", so paths with spaces survive.
  local entry path
  git config -z -f .gitmodules --get-regexp '\.path$' 2>/dev/null \
    | while IFS= read -r -d '' entry; do
        path="${entry#*$'\n'}"
        case "$path" in deprecated/*) continue ;; esac
        printf '%s\n' "$path"
      done
}

# True if $1 is a repo checked out in its own right. An uninitialised
# submodule is an empty directory, where `git -C` silently finds the
# superproject instead and every check would describe the wrong repo.
repo_present() {
  [ "$1" = "." ] && return 0
  [ -e "$1/.git" ] || return 1
  [ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$1" && pwd -P)" ]
}

missing_msg() {
  echo "$1 is not checked out (an uninitialised submodule) — initialise it first (e.g. git submodule update --init $1, or the project's own worktree setup), then switch it to the right branch."
}

list_repos() {
  echo "."
  list_submodules
}

repo_branch() {
  git -C "$1" symbolic-ref --short -q HEAD || true
}

repo_is_dirty() {
  [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]
}

# Like repo_is_dirty, but ignores submodule pointer drift (a submodule whose
# checked-out commit differs from what this repo's index currently records).
# That drift is the expected, normal in-flight state of this flow's own
# "commit submodule first, bump the superproject's pointer last" workflow —
# treating it as "dirty" would false-block start/sync/finish on ordinary use.
# Use this at safety gates that decide whether it's safe to switch branches;
# keep plain repo_is_dirty where the point IS to surface pointer drift (e.g.
# cmd_pending, which tells the user "commit here to bump the pointer").
# Verified: a `git merge --ff-only` in the superproject never conflicts on pure
# (unstaged) gitlink drift alone — updating a submodule's recorded pointer via
# fast-forward doesn't touch the submodule's own working tree, so there's
# nothing for the merge to "overwrite" there. The one theoretical residual (a
# *staged* `git add <submodule>` whose value conflicts with the incoming
# fast-forward) falls through to this script's normal run_step failure
# handling below, same as any other unexpected git failure.
repo_is_dirty_ignoring_submodules() {
  [ -n "$(git -C "$1" status --porcelain --ignore-submodules=all 2>/dev/null)" ]
}

# Prints the path of another worktree of $1's repository that holds branch $2
# (git refuses to check out or delete such a branch here), or nothing. A
# worktree in the middle of a rebase of $2 shows as detached but still holds
# it. A submodule's own checkout is listed by `git worktree list` under its git
# dir (e.g. .git/modules/<name>), not its working tree: that path counts as
# "here", and when it is another checkout, its working tree is printed instead.
repo_branch_worktree() {
  local here gitdir line w wp wgd hn
  here="$(cd "$1" && pwd -P)"
  gitdir="$(cd "$(git -C "$1" rev-parse --absolute-git-dir)" && pwd -P)"
  git -C "$1" worktree list --porcelain | while IFS= read -r line; do
    case "$line" in
      "worktree "*) w="${line#worktree }"; continue ;;
      "branch refs/heads/$2") ;;
      detached)
        wgd="$(git -C "$w" rev-parse --absolute-git-dir 2>/dev/null)" || continue
        hn="$(cat "$wgd/rebase-merge/head-name" "$wgd/rebase-apply/head-name" 2>/dev/null | head -n 1)"
        [ "$hn" = "refs/heads/$2" ] || continue
        ;;
      *) continue ;;
    esac
    wp="$(cd "$w" 2>/dev/null && pwd -P)"
    if [ "$wp" = "$here" ] || [ "$wp" = "$gitdir" ]; then
      continue
    fi
    if [ ! -e "$w/.git" ] && [ -f "$w/HEAD" ]; then
      w="$(git --git-dir="$w" rev-parse --show-toplevel 2>/dev/null || echo "$w")"
    fi
    echo "$w"
    break
  done
}

repo_local_branch_exists() {
  git -C "$1" show-ref --verify --quiet "refs/heads/$2"
}

# Fetches origin's <branch> into refs/remotes/origin/<branch>. The explicit
# refspec matters: a plain `git fetch origin <branch>` only updates that ref
# when the configured fetch refspec covers it, which single-branch/shallow
# clones' don't — leaving origin/<branch> missing or stale.
# Read-only with respect to local branches/HEAD — safe to call during preflight.
repo_fetch_branch() {
  git -C "$1" fetch --quiet origin "+refs/heads/$2:refs/remotes/origin/$2" 2>/dev/null || true
}

# Create local <branch> from origin/<branch> and make origin/<branch> its
# upstream. Not `checkout -b --track`: that refuses ("starting point is not a
# branch") when origin/<branch> isn't covered by the configured fetch refspec,
# i.e. exactly the single-branch/shallow clones repo_fetch_branch handles.
repo_checkout_tracking() {
  gitnr -C "$1" checkout --no-track -b "$2" "origin/$2" \
    && git -C "$1" config "branch.$2.remote" origin \
    && git -C "$1" config "branch.$2.merge" "refs/heads/$2"
}

repo_remote_branch_exists() {
  git -C "$1" show-ref --verify --quiet "refs/remotes/origin/$2"
}

repo_ahead_behind_local() {
  # ahead/behind of the LOCAL branch ref (not necessarily checked out) vs origin/<branch>
  local path="$1" branch="$2"
  repo_remote_branch_exists "$path" "$branch" || return 1
  git -C "$path" rev-list --left-right --count "origin/$branch...$branch" 2>/dev/null | awk '{print $2, $1}'
}

repo_commits_ahead_of_base() {
  local path="$1" branch="$2" base="$3"
  git -C "$path" rev-list --count "$base..$branch" 2>/dev/null || echo 0
}

repo_is_ancestor() {
  # true if $2 is fully merged into $3
  git -C "$1" merge-base --is-ancestor "$2" "$3" 2>/dev/null
}

# Per (repo, change-id) memory of which branch it was started from, so
# 'sync'/'finish' don't need the base branch repeated on every call. The
# change-id is the config subsection ("flow-base.<change-id>.base"), which may
# hold any branch-name character, including the "/" of prefixed names like
# "wt/<topic>"; a plain "flow-base.<change-id>" key only allows letters,
# digits and "-". That older key is still read and removed for branches
# started before.
repo_set_base() {
  git -C "$1" config "flow-base.$2.base" "$3"
}

# The older key is only consulted for change-ids it could have been written
# for: otherwise "flow-base.<a.base>" would be change-id "a"'s new key.
old_key_ok() {
  case "$1" in
    [A-Za-z]*) case "$1" in *[!A-Za-z0-9-]*) return 1 ;; esac; return 0 ;;
    *) return 1 ;;
  esac
}

repo_get_base() {
  git -C "$1" config --get "flow-base.$2.base" 2>/dev/null && return 0
  old_key_ok "$2" && git -C "$1" config --get "flow-base.$2" 2>/dev/null
  return 0
}

repo_unset_base() {
  git -C "$1" config --unset "flow-base.$2.base" 2>/dev/null || true
  old_key_ok "$2" && { git -C "$1" config --unset "flow-base.$2" 2>/dev/null || true; }
  return 0
}

# Best-effort guess of a repo's default branch from origin/HEAD (prints nothing
# if origin/HEAD isn't set). Never hardcode a branch name here.
repo_default_base() {
  local ref
  ref="$(git -C "$1" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" || return 0
  echo "${ref#origin/}"
}

require_change_id() {
  if [ -z "${1:-}" ]; then
    echo "Usage: $0 ${2:-<cmd>} <change-id>" >&2
    exit 1
  fi
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

# --- branches --------------------------------------------------------------

cmd_branches() {
  # Local branches of the superproject only — the base branch is chosen once
  # here and then applied identically to the submodules in 'start'.
  git branch --list --format='%(refname:short)'
}

# --- status --------------------------------------------------------------

cmd_status() {
  local path branch dirty ab ahead behind
  while IFS= read -r path; do
    repo_present "$path" || { echo "  $path: MISSING (not checked out — uninitialised submodule)"; continue; }
    branch="$(repo_branch "$path")"
    dirty="clean"; repo_is_dirty "$path" && dirty="DIRTY"
    printf '  %s: branch=%s %s' "$path" "${branch:-<DETACHED>}" "$dirty"
    if [ -n "$branch" ]; then
      repo_fetch_branch "$path" "$branch"
      if ab="$(repo_ahead_behind_local "$path" "$branch")"; then
        ahead="$(echo "$ab" | awk '{print $1}')"
        behind="$(echo "$ab" | awk '{print $2}')"
        printf ' ahead=%s behind=%s (vs origin/%s)' "$ahead" "$behind" "$branch"
      else
        printf ' (no origin/%s yet)' "$branch"
      fi
    fi
    echo
  done < <(list_repos)
}

# --- start ------------------------------------------------------------------

cmd_start() {
  local change_id="$1" base_branch="$2"
  local -a act_paths=() act_ff=()
  local -a skip_paths=()
  local path branch blocked=0

  if ! git check-ref-format --branch "$change_id" >/dev/null 2>&1; then
    echo "BLOCKED: '$change_id' is not a valid branch name. Nothing changed." >&2
    return 2
  fi

  while IFS= read -r path; do
    repo_present "$path" || { echo "BLOCKED: $(missing_msg "$path")" >&2; blocked=1; continue; }
    if repo_is_dirty_ignoring_submodules "$path"; then
      echo "BLOCKED: $path has uncommitted changes. Commit or stash first." >&2
      blocked=1
      continue
    fi
    branch="$(repo_branch "$path")"
    if [ "$branch" = "$change_id" ]; then
      # A re-run (e.g. after a start that stopped midway) must use the same
      # base, or the remaining repos would branch off a different one.
      local recorded
      recorded="$(repo_get_base "$path" "$change_id")"
      if [ -n "$recorded" ] && [ "$recorded" != "$base_branch" ]; then
        echo "BLOCKED: $path is already on '$change_id', started from '$recorded', not '$base_branch'. Re-run with '$recorded' as the base, or set this change aside by hand if '$base_branch' is what you meant." >&2
        blocked=1
        continue
      fi
      echo "SKIP: $path is already on '$change_id'."
      skip_paths+=("$path")
      continue
    fi
    if repo_local_branch_exists "$path" "$change_id"; then
      echo "BLOCKED: $path already has a local branch '$change_id' (but you're on '$branch'). This change may already be started elsewhere — use 'sync' instead of 'start', or delete the stale branch by hand if this was a mistake." >&2
      blocked=1
      continue
    fi
    repo_fetch_branch "$path" "$change_id"
    if repo_remote_branch_exists "$path" "$change_id"; then
      echo "BLOCKED: $path already has origin/$change_id — this change was started on another machine. Use 'sync $change_id' to pick it up instead of starting it again." >&2
      blocked=1
      continue
    fi
    if ! repo_local_branch_exists "$path" "$base_branch"; then
      echo "BLOCKED: $path has no local branch '$base_branch' to start from." >&2
      blocked=1
      continue
    fi
    if [ "$branch" != "$base_branch" ]; then
      echo "BLOCKED: $path is currently on '$branch', not '$base_branch'. Checkout $base_branch by hand first (finish or set aside whatever you're on there) before starting a new change." >&2
      blocked=1
      continue
    fi
    repo_fetch_branch "$path" "$base_branch"
    local ab ahead behind
    if ab="$(repo_ahead_behind_local "$path" "$base_branch")"; then
      ahead="$(echo "$ab" | awk '{print $1}')"
      behind="$(echo "$ab" | awk '{print $2}')"
      if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
        echo "BLOCKED: $path ($base_branch) has diverged from origin/$base_branch (ahead $ahead, behind $behind). Resolve by hand (see yueban-git-safe-sync) before branching off it." >&2
        blocked=1
        continue
      fi
    else
      behind=0
    fi
    act_paths+=("$path")
    act_ff+=("$behind")
  done < <(list_repos)

  if [ "$blocked" -ne 0 ]; then
    echo
    echo "Nothing changed. Fix the BLOCKED items above and re-run." >&2
    return 2
  fi

  local i
  local -a done_paths=()
  for i in "${!act_paths[@]}"; do
    path="${act_paths[$i]}"
    if [ "${act_ff[$i]}" -gt 0 ]; then
      echo "-- $path: fast-forwarding $base_branch to origin/$base_branch --"
      run_step "$path: fast-forward of $base_branch failed unexpectedly. Stopping — already done: ${done_paths[*]:-<none>}. Resolve $path by hand, then re-run for the remaining repos." \
        gitnr -C "$path" merge --ff-only "origin/$base_branch" || return 2
    fi
    echo "-- $path: creating '$change_id' from $base_branch --"
    run_step "$path: 'git checkout -b $change_id' failed unexpectedly (e.g. an invalid branch name?). Stopping — already done: ${done_paths[*]:-<none>}. Resolve $path by hand, then re-run for the remaining repos." \
      gitnr -C "$path" checkout -b "$change_id" || return 2
    run_step "$path: recording base '$base_branch' for '$change_id' in git config failed. '$change_id' was created; pass --base $base_branch to 'finish' for this repo. Stopping — already done: ${done_paths[*]:-<none>}." \
      repo_set_base "$path" "$change_id" "$base_branch" || return 2
    done_paths+=("$path")
  done

  echo
  echo "Done. '$change_id' (base: $base_branch) is now checked out in: ${done_paths[*]:-<none>}${skip_paths[*]:+ (already on it: ${skip_paths[*]})}"
}

# --- pending -----------------------------------------------------------

cmd_pending() {
  # Read-only report to drive the commit step: which repos on <change-id>
  # have uncommitted changes, in the order they should be committed in
  # (submodules first, superproject last) — see SKILL.md for why the order
  # matters. Actually composing commit messages is delegated to the
  # yueban-git-commit skill, not done here.
  local change_id="$1"
  local path branch any_dirty=0

  echo "== $change_id: pending changes (commit submodules first, superproject last) =="
  while IFS= read -r path; do
    [ "$path" = "." ] && continue
    repo_present "$path" || continue
    branch="$(repo_branch "$path")"
    if [ "$branch" != "$change_id" ]; then
      echo "  $path: not on '$change_id' (currently '${branch:-<DETACHED>}') — skipped"
      continue
    fi
    if repo_is_dirty "$path"; then
      any_dirty=1
      echo "  $path: DIRTY"
      git -C "$path" status --short | sed 's/^/    /'
    else
      echo "  $path: clean"
    fi
  done < <(list_submodules)

  branch="$(repo_branch ".")"
  if [ "$branch" != "$change_id" ]; then
    echo "  . (superproject): not on '$change_id' (currently '${branch:-<DETACHED>}') — skipped"
  elif repo_is_dirty "."; then
    any_dirty=1
    echo "  . (superproject): DIRTY"
    git status --short | sed 's/^/    /'
  else
    echo "  . (superproject): clean"
  fi

  echo
  if [ "$any_dirty" -eq 1 ]; then
    echo "Commit each DIRTY submodule above via the yueban-git-commit skill (commit + push inside that submodule) first, then the superproject last (its commit records the new submodule pointers)."
  else
    echo "Nothing pending."
  fi
}

# --- sync ------------------------------------------------------------------

cmd_sync() {
  local change_id="$1"
  local -a do_switch=() do_ff=()
  local path branch blocked=0

  while IFS= read -r path; do
    repo_present "$path" || { echo "BLOCKED: $(missing_msg "$path")" >&2; blocked=1; continue; }
    branch="$(repo_branch "$path")"
    if [ -z "$branch" ]; then
      echo "BLOCKED: $path is in detached HEAD — resolve manually (checkout the intended branch) before syncing." >&2
      blocked=1
      continue
    fi
    repo_fetch_branch "$path" "$change_id"

    if [ "$branch" = "$change_id" ]; then
      local ab ahead behind
      if ab="$(repo_ahead_behind_local "$path" "$change_id")"; then
        ahead="$(echo "$ab" | awk '{print $1}')"
        behind="$(echo "$ab" | awk '{print $2}')"
        if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
          echo "BLOCKED: $path ($change_id) has diverged from origin/$change_id (ahead $ahead, behind $behind). Merge/rebase by hand." >&2
          blocked=1
          continue
        fi
        if repo_is_dirty_ignoring_submodules "$path" && [ "$behind" -gt 0 ]; then
          echo "BLOCKED: $path has uncommitted changes and origin/$change_id has new commits. Commit or stash first." >&2
          blocked=1
          continue
        fi
        do_switch+=(""); do_ff+=("$([ "$behind" -gt 0 ] && echo 1 || echo 0)")
      else
        echo "OK: $path is on '$change_id', nothing on origin yet."
        do_switch+=(""); do_ff+=("0")
      fi
      continue
    fi

    # not currently on change_id
    if repo_is_dirty_ignoring_submodules "$path"; then
      echo "BLOCKED: $path has uncommitted changes on '$branch' — can't switch to '$change_id'. Commit or stash first." >&2
      blocked=1
      continue
    fi
    if repo_local_branch_exists "$path" "$change_id"; then
      local ab ahead behind elsewhere
      elsewhere="$(repo_branch_worktree "$path" "$change_id")"
      if [ -n "$elsewhere" ]; then
        echo "BLOCKED: $path can't switch to '$change_id': it is checked out in another worktree ($elsewhere). Work there, or switch that worktree to another branch first." >&2
        blocked=1
        continue
      fi
      if ab="$(repo_ahead_behind_local "$path" "$change_id")"; then
        ahead="$(echo "$ab" | awk '{print $1}')"
        behind="$(echo "$ab" | awk '{print $2}')"
        if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
          echo "BLOCKED: $path ($change_id) has diverged from origin/$change_id (ahead $ahead, behind $behind). Merge/rebase by hand." >&2
          blocked=1
          continue
        fi
        do_switch+=("checkout"); do_ff+=("$([ "$behind" -gt 0 ] && echo 1 || echo 0)")
      else
        do_switch+=("checkout"); do_ff+=("0")
      fi
    elif repo_remote_branch_exists "$path" "$change_id"; then
      do_switch+=("track"); do_ff+=("0")
    else
      echo "BLOCKED: no local or remote branch '$change_id' found in $path. Has this repo been through 'start' yet (on any machine)?" >&2
      blocked=1
      continue
    fi
  done < <(list_repos)

  if [ "$blocked" -ne 0 ]; then
    echo
    echo "Nothing changed. Fix the BLOCKED items above and re-run." >&2
    return 2
  fi

  local i=0
  local -a done_paths=()
  while IFS= read -r path; do
    local mode="${do_switch[$i]:-}" ff="${do_ff[$i]:-0}"
    case "$mode" in
      checkout)
        echo "-- $path: checkout existing local '$change_id' --"
        run_step "$path: 'git checkout $change_id' failed unexpectedly. Stopping — already done: ${done_paths[*]:-<none>}. Resolve $path by hand, then re-run." \
          gitnr -C "$path" checkout "$change_id" || return 2
        ;;
      track)
        echo "-- $path: checkout '$change_id' tracking origin/$change_id --"
        run_step "$path: creating '$change_id' from origin/$change_id (with origin/$change_id as upstream) failed unexpectedly. Stopping — already done: ${done_paths[*]:-<none>}. Resolve $path by hand, then re-run." \
          repo_checkout_tracking "$path" "$change_id" || return 2
        ff=0
        ;;
    esac
    if [ "$ff" -eq 1 ]; then
      echo "-- $path: fast-forwarding $change_id to origin/$change_id --"
      run_step "$path: fast-forward of $change_id failed unexpectedly. Stopping — already done: ${done_paths[*]:-<none>}. Resolve $path by hand, then re-run." \
        gitnr -C "$path" merge --ff-only "origin/$change_id" || return 2
    fi
    done_paths+=("$path")
    i=$((i + 1))
  done < <(list_repos)

  local off="" now
  while IFS= read -r path; do
    now="$(repo_branch "$path")"
    [ "$now" = "$change_id" ] || off="$off $path(${now:-detached})"
  done < <(list_repos)
  if [ -n "$off" ]; then
    echo "FAILED: sync finished but these repos are not on '$change_id':$off — check them by hand." >&2
    return 2
  fi

  echo
  echo "Done."
  cmd_status
}

# --- finish ------------------------------------------------------------------

cmd_finish() {
  local change_id="$1" base_override="$2" cleanup="$3"
  local path

  # Prints the base branch for $path, or returns 1 (with a BLOCKED message on
  # stderr) if none can be determined or it doesn't exist locally — comparing
  # against a missing base would otherwise look like an "empty" branch.
  resolve_base() {
    local path="$1" base
    if [ -n "$base_override" ]; then
      base="$base_override"
    else
      base="$(repo_get_base "$path" "$change_id")"
      [ -n "$base" ] || base="$(repo_default_base "$path")"
    fi
    if [ -z "$base" ]; then
      echo "BLOCKED: $path has no recorded base for '$change_id' and origin/HEAD is unset — pass --base <branch>." >&2
      return 1
    fi
    if ! repo_local_branch_exists "$path" "$base"; then
      if repo_remote_branch_exists "$path" "$base"; then
        echo "BLOCKED: $path has no local branch '$base' (it exists on origin) — check it out first (git -C $path checkout $base), then re-run." >&2
      else
        echo "BLOCKED: $path has no branch '$base' locally or on origin to compare '$change_id' against — check the name, or pass --base <branch>." >&2
      fi
      return 1
    fi
    echo "$base"
  }

  if [ "$cleanup" = "1" ]; then
    local -a can_delete=() remote_sha=()
    local blocked=0
    while IFS= read -r path; do
      repo_present "$path" || { echo "BLOCKED: $(missing_msg "$path")" >&2; blocked=1; continue; }
      if ! repo_local_branch_exists "$path" "$change_id"; then
        echo "SKIP: $path has no local '$change_id' branch, nothing to clean up."
        can_delete+=("0"); remote_sha+=("")
        continue
      fi
      local base; base="$(resolve_base "$path")" || { blocked=1; can_delete+=("0"); remote_sha+=(""); continue; }
      repo_fetch_branch "$path" "$base"
      # origin/<change-id> may hold commits pushed from another machine that
      # never reached this one: deleting it would lose them.
      local rsha=""
      git -C "$path" fetch --quiet --prune origin "+refs/heads/$change_id:refs/remotes/origin/$change_id" 2>/dev/null || true
      if repo_remote_branch_exists "$path" "$change_id"; then
        rsha="$(git -C "$path" rev-parse "refs/remotes/origin/$change_id")"
        if ! repo_is_ancestor "$path" "$rsha" "$base" \
          && ! { repo_remote_branch_exists "$path" "$base" && repo_is_ancestor "$path" "$rsha" "origin/$base"; }; then
          echo "BLOCKED: $path's origin/$change_id has commits not merged into $base (or origin/$base) — probably pushed from another machine. Sync and merge them first; cleanup would delete them from origin." >&2
          blocked=1
          continue
        fi
      fi
      local ab
      if ab="$(repo_ahead_behind_local "$path" "$base")"; then
        local ahead; ahead="$(echo "$ab" | awk '{print $1}')"
        if [ "$ahead" -gt 0 ]; then
          echo "BLOCKED: $path's local $base is ahead of origin/$base by $ahead commit(s) — push $base before deleting '$change_id' (it's your only remote copy of that work until then)." >&2
          blocked=1
          continue
        fi
      fi
      if ! repo_is_ancestor "$path" "$change_id" "$base"; then
        # Local $base may just be stale (e.g. merged upstream via a PR but
        # never pulled locally) — repo_fetch_branch above already updated
        # origin/$base, so check that too before blocking.
        if repo_remote_branch_exists "$path" "$base" && repo_is_ancestor "$path" "$change_id" "origin/$base"; then
          echo "NOTE: $path's local $base is behind origin/$base and doesn't contain '$change_id' yet, but origin/$base already does — proceeding. Update local $base afterwards (e.g. via yueban-git-safe-sync)."
        else
          echo "BLOCKED: $path's '$change_id' is not merged into local $base yet. Merge it by hand first." >&2
          blocked=1
          continue
        fi
      fi
      if [ "$(repo_branch "$path")" = "$change_id" ] && repo_is_dirty_ignoring_submodules "$path"; then
        echo "BLOCKED: $path is currently on '$change_id' with uncommitted changes — cleanup needs to switch it back to '$base' before deleting the branch. Commit or stash first." >&2
        blocked=1
        continue
      fi
      local elsewhere
      elsewhere="$(repo_branch_worktree "$path" "$change_id")"
      if [ -n "$elsewhere" ]; then
        echo "BLOCKED: $path's '$change_id' is checked out in another worktree ($elsewhere) — git won't delete it. Remove that worktree or switch it to another branch first." >&2
        blocked=1
        continue
      fi
      if [ "$(repo_branch "$path")" = "$change_id" ]; then
        local base_wt
        base_wt="$(repo_branch_worktree "$path" "$base")"
        if [ -n "$base_wt" ]; then
          echo "BLOCKED: $path is on '$change_id' and cleanup needs to switch it to '$base', but '$base' is checked out in another worktree ($base_wt). Run cleanup from that worktree instead, or switch it to another branch first." >&2
          blocked=1
          continue
        fi
      fi
      can_delete+=("1"); remote_sha+=("$rsha")
    done < <(list_repos)

    if [ "$blocked" -ne 0 ]; then
      echo
      echo "Nothing deleted. Fix the BLOCKED items above and re-run." >&2
      return 2
    fi

    local i=0
    local -a deleted_paths=()
    while IFS= read -r path; do
      if [ "${can_delete[$i]:-0}" = "1" ]; then
        if [ "$(repo_branch "$path")" = "$change_id" ]; then
          local base; base="$(resolve_base "$path")" || return 2
          echo "-- $path: currently on '$change_id', switching to '$base' first --"
          run_step "$path: 'git checkout $base' failed unexpectedly. Stopping — already deleted: ${deleted_paths[*]:-<none>}. Resolve $path by hand, then re-run --cleanup for the rest." \
            gitnr -C "$path" checkout "$base" || return 2
        fi
        echo "-- $path: deleting local branch '$change_id' --"
        # -D, not -d: the checks above already proved it is merged into $base
        # or origin/$base; -d judges by the branch's upstream or HEAD instead
        # and would refuse halfway through.
        run_step "$path: 'git branch -D $change_id' failed unexpectedly. Stopping — already deleted: ${deleted_paths[*]:-<none>}. Resolve $path by hand, then re-run --cleanup for the rest." \
          git -C "$path" branch -D "$change_id" || return 2
        repo_unset_base "$path" "$change_id"
        local rsha="${remote_sha[$i]:-}"
        if [ -n "$rsha" ]; then
          echo "-- $path: deleting origin/$change_id --"
          # The lease makes the delete fail if someone pushed after the check.
          if ! git -C "$path" push --quiet --force-with-lease="refs/heads/$change_id:$rsha" origin ":refs/heads/$change_id"; then
            echo "   NOT deleted: origin/$change_id changed since the check (or the push failed) — look at it before deleting it by hand."
          fi
        fi
        deleted_paths+=("$path")
      fi
      i=$((i + 1))
    done < <(list_repos)
    echo
    echo "Cleanup done."
    return 0
  fi

  echo "== $change_id: merge readiness report =="
  echo "(submodules first — merge/push each one's $change_id into its own base before touching the superproject)"
  echo
  local unresolved=0
  while IFS= read -r path; do
    repo_present "$path" || { echo "  $path: MISSING (not checked out — uninitialised submodule)"; continue; }
    if ! repo_local_branch_exists "$path" "$change_id"; then
      echo "  $path: no local '$change_id' branch (run 'sync' first if it exists on origin, or 'start' if not)"
      continue
    fi
    local base; base="$(resolve_base "$path")" || { echo "  $path: BASE UNAVAILABLE — see BLOCKED above"; unresolved=1; continue; }
    local base_note=""
    [ -z "$(repo_get_base "$path" "$change_id")" ] && [ -z "$base_override" ] && base_note=" (no recorded base — using origin/HEAD's '$base', pass --base to override)"
    local commits; commits="$(repo_commits_ahead_of_base "$path" "$change_id" "$base")"
    repo_fetch_branch "$path" "$base"
    repo_fetch_branch "$path" "$change_id"
    local pushed="no origin/$change_id yet"
    local ab
    if ab="$(repo_ahead_behind_local "$path" "$change_id")"; then
      local ahead behind
      ahead="$(echo "$ab" | awk '{print $1}')"
      behind="$(echo "$ab" | awk '{print $2}')"
      if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
        pushed="in sync with origin"
      else
        pushed="ahead=$ahead behind=$behind vs origin — sync/push before merging"
      fi
    fi
    local merged="not merged into local $base"
    if repo_is_ancestor "$path" "$change_id" "$base"; then
      merged="already merged into local $base"
    elif repo_remote_branch_exists "$path" "$base" && repo_is_ancestor "$path" "$change_id" "origin/$base"; then
      merged="already merged into origin/$base (local $base not updated yet)"
    fi
    local remote_extra=""
    if repo_remote_branch_exists "$path" "$change_id"; then
      local -a not_in=("$base")
      repo_remote_branch_exists "$path" "$base" && not_in+=("origin/$base")
      local n; n="$(git -C "$path" rev-list --count "origin/$change_id" --not "${not_in[@]}" 2>/dev/null || echo 0)"
      [ "$n" -gt 0 ] && remote_extra=" — WARNING: origin/$change_id has $n commit(s) not in $base; sync before merging or cleaning up"
    fi
    if [ "$commits" = "0" ]; then
      echo "  $path: no commits beyond local $base (never committed, or already merged)$base_note, $pushed$remote_extra"
    else
      echo "  $path: $commits commit(s) ahead of $base$base_note, $pushed, $merged$remote_extra"
    fi
  done < <(list_submodules; echo ".")
  echo
  if [ "$unresolved" != "0" ]; then
    echo "Some repos above are BASE UNAVAILABLE — fix that (see BLOCKED messages) and re-run before merging or cleaning up."
    return 2
  fi
  echo "Next steps (manual, this tool does not merge for you):"
  echo "  1. For each submodule with real commits: merge/PR '$change_id' into its base branch, then push that base branch."
  echo "  2. In the superproject: 'git add <submodule>' to record the new base-branch pointers, commit, then merge/PR the superproject's '$change_id' into its own base and push."
  echo "  3. Once everything above is merged and pushed, run: $0 finish $change_id --cleanup"
}

# --- main --------------------------------------------------------------

case "${1:-}" in
  branches) cmd_branches ;;
  status) cmd_status ;;
  start)
    require_change_id "${2:-}" "start"
    if [ -z "${3:-}" ]; then
      echo "Usage: $0 start <change-id> <base-branch>" >&2
      exit 1
    fi
    cmd_start "$2" "$3"
    ;;
  pending)
    require_change_id "${2:-}" "pending"
    cmd_pending "$2"
    ;;
  sync)
    require_change_id "${2:-}" "sync"
    cmd_sync "$2"
    ;;
  finish)
    require_change_id "${2:-}" "finish"
    change_id="$2"; shift 2
    base_override=""
    cleanup=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --base)
          base_override="${2:-}"
          if [ -z "$base_override" ]; then echo "Usage: $0 finish <change-id> --base <branch>" >&2; exit 1; fi
          shift 2
          ;;
        --cleanup) cleanup=1; shift ;;
        *) echo "Unknown finish option: $1" >&2; exit 1 ;;
      esac
    done
    cmd_finish "$change_id" "$base_override" "$cleanup"
    ;;
  *)
    echo "Usage: $0 {branches|status|start <change-id> <base-branch>|pending <change-id>|sync <change-id>|finish <change-id> [--base <branch>] [--cleanup]}" >&2
    exit 1
    ;;
esac
