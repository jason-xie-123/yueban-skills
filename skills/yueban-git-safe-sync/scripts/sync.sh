#!/usr/bin/env bash
# submodule-safe-sync: keep submodules on their tracked branch across pull/push,
# instead of the git-default "checkout by recorded SHA" behavior that detaches
# HEAD. See ../SKILL.md for the full rationale and workflow this script serves.
#
# Usage:
#   sync.sh status
#   sync.sh pull
#   sync.sh push [--dry-run]
#   sync.sh merge-base <base-branch>
#   sync.sh pr <base-branch> [--dry-run] [--draft]
#
# Exit codes:
#   0 = clean / completed
#   1 = usage error
#   2 = at least one submodule (or the superproject) is blocked; nothing was
#       changed for pull, and nothing was pushed for push. For merge-base,
#       everything up to (not including) the first conflicting repo was
#       already merged; for pr, every PR before the first failed
#       `gh pr create` was already opened — see stderr for exactly which ones.

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

# Like sm_is_dirty, but for a path that may be the superproject ("."): a
# submodule pointer simply being ahead of what the superproject last recorded
# is the normal, expected state merge-base/pull produce (see cmd_pull above),
# not "uncommitted changes" — so the superproject's own check ignores
# submodule state and only looks at its own tracked files.
path_is_dirty() {
  if [ "$1" = "." ]; then
    [ -n "$(git status --porcelain --ignore-submodules=all 2>/dev/null)" ]
  else
    sm_is_dirty "$1"
  fi
}

# Submodule paths whose checked-out commit differs from what the
# superproject's HEAD records (staged or not). merge-base tolerates this, but
# pr must not: the superproject's PR would reference the old submodule SHAs.
super_uncommitted_gitlinks() {
  git diff --name-only --ignore-submodules=dirty HEAD 2>/dev/null
}

# Run gh inside a repo directory — gh has no `-C` flag like git does.
gh_in() {
  local path="$1"; shift
  (cd "$path" && gh "$@")
}

sm_recorded_sha() {
  # What the superproject's HEAD currently records for this submodule path.
  git rev-parse -q --verify "HEAD:$1" 2>/dev/null || true
}

sm_head_sha() {
  git -C "$1" rev-parse HEAD 2>/dev/null || true
}

# Fetch origin's <branch> into refs/remotes/origin/<branch> with an explicit
# refspec: a plain `git fetch origin <branch>` only updates that ref when the
# configured fetch refspec covers it, which single-branch/shallow clones' don't
# — leaving a stale origin/<branch> that would be compared/merged silently.
fetch_branch() {
  git -C "$1" fetch --quiet origin "+refs/heads/$2:refs/remotes/origin/$2" 2>/dev/null
}

# ahead/behind counts of local branch vs its origin/<branch>, after a fetch.
# Prints "AHEAD BEHIND" or nothing if origin/<branch> doesn't exist yet.
sm_ahead_behind() {
  local path="$1" branch="$2"
  fetch_branch "$path" "$branch" || true
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

# --- merge-base --------------------------------------------------------

# Superproject (".") plus every active submodule, in that order — used by
# merge-base and pr, which (unlike pull/push) treat the superproject and its
# submodules identically instead of needing push-order sequencing.
all_paths() {
  echo "."
  list_submodules
}

cmd_merge_base() {
  local base_branch="${1:-}"
  if [ $# -ne 1 ] || [ -z "$base_branch" ] || [ "${base_branch#-}" != "$base_branch" ]; then
    echo "Usage: $0 merge-base <base-branch>" >&2
    return 1
  fi

  local -a merge_paths=() merge_branches=() skip_notes=()
  local path branch
  local blocked=0

  while IFS= read -r path; do
    [ -d "$path" ] || { echo "BLOCKED: $path is not checked out." >&2; blocked=1; continue; }
    branch="$(sm_branch "$path")"
    if [ -z "$branch" ]; then
      echo "BLOCKED: $path is in detached HEAD. Resolve manually first (checkout the intended branch)." >&2
      blocked=1
      continue
    fi
    if path_is_dirty "$path"; then
      echo "BLOCKED: $path has uncommitted changes. Commit or stash first." >&2
      blocked=1
      continue
    fi
    if [ "$branch" = "$base_branch" ]; then
      skip_notes+=("$path: already on $base_branch, nothing to merge")
      continue
    fi
    if ! fetch_branch "$path" "$base_branch"; then
      echo "BLOCKED: $path — origin/$base_branch not found (fetch failed). Check the branch name exists on that remote." >&2
      blocked=1
      continue
    fi
    if git -C "$path" merge-base --is-ancestor "origin/$base_branch" HEAD 2>/dev/null; then
      skip_notes+=("$path ($branch): already up to date with origin/$base_branch")
      continue
    fi
    merge_paths+=("$path")
    merge_branches+=("$branch")
  done < <(all_paths)

  if [ "$blocked" -ne 0 ]; then
    echo
    echo "Nothing merged. Fix the BLOCKED items above and re-run." >&2
    return 2
  fi

  local note
  for note in "${skip_notes[@]:-}"; do
    [ -n "$note" ] && echo "SKIP: $note"
  done

  if [ "${#merge_paths[@]}" -eq 0 ]; then
    echo
    echo "Nothing to merge — every repo is already up to date with origin/$base_branch."
    return 0
  fi

  # Unlike pull/push, a merge conflict can only be discovered by attempting
  # the merge — preflight above can't rule it out. So this loop is NOT
  # all-or-nothing: on the first conflict we stop immediately, leave that repo
  # mid-merge for the user to resolve by hand, and report exactly which repos
  # (if any) were already merged before it, instead of silently retrying or
  # aborting on the user's behalf.
  local i
  local -a merged_paths=()
  for i in "${!merge_paths[@]}"; do
    path="${merge_paths[$i]}"; branch="${merge_branches[$i]}"
    echo "-- $path: merging origin/$base_branch into $branch --"
    # --no-edit: take git's default merge message instead of opening an editor
    # when run from an interactive terminal.
    if ! git -C "$path" merge --no-edit origin/"$base_branch"; then
      if ! git -C "$path" rev-parse -q --verify MERGE_HEAD >/dev/null; then
        echo "BLOCKED: $path — merge of origin/$base_branch into $branch failed before starting (see git's message above); $path was not changed. Already merged before this: ${merged_paths[*]:-<none>}. Stopping — remaining repos were not touched." >&2
        return 2
      fi
      local hint=""
      if [ "$path" = "." ]; then
        hint=" If the conflicts are on submodule paths (gitlinks), resolve each with \`git add <submodule-path>\` to record that submodule's current HEAD — its own merge happens when you re-run this command, and the resulting pointer update is committed later like any other."
      fi
      echo "BLOCKED: $path — merge of origin/$base_branch into $branch hit a conflict. The repo is left mid-merge: run \`git -C $path status\` to see conflicts, then \`git -C $path commit\` to finish, or \`git -C $path merge --abort\` to cancel.$hint Already merged before this: ${merged_paths[*]:-<none>}. Stopping — remaining repos were not touched." >&2
      return 2
    fi
    merged_paths+=("$path")
  done

  echo
  echo "Done. Merged origin/$base_branch into: ${merged_paths[*]}."
  echo "Nothing was pushed — run 'scripts/sync.sh push' when ready to publish, or 'scripts/sync.sh pr $base_branch' to open PRs."
}

# --- pr ------------------------------------------------------------------

cmd_pr() {
  local base_branch="" dry_run=0 draft=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1 ;;
      --draft) draft=1 ;;
      -*)
        echo "Usage: $0 pr <base-branch> [--dry-run] [--draft]" >&2
        return 1
        ;;
      *)
        if [ -z "$base_branch" ]; then
          base_branch="$1"
        else
          echo "Usage: $0 pr <base-branch> [--dry-run] [--draft]" >&2
          return 1
        fi
        ;;
    esac
    shift
  done
  if [ -z "$base_branch" ]; then
    echo "Usage: $0 pr <base-branch> [--dry-run] [--draft]" >&2
    return 1
  fi

  if ! command -v gh >/dev/null 2>&1; then
    echo "BLOCKED: gh (GitHub CLI) not found. Install it first (https://cli.github.com), then \`gh auth login\`." >&2
    return 2
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "BLOCKED: gh is not logged in. Run \`gh auth login\` first." >&2
    return 2
  fi

  local -a pr_paths=() pr_branches=() pr_titles=() pr_bodies=() skip_notes=()
  local path branch
  local blocked=0

  while IFS= read -r path; do
    [ -d "$path" ] || { echo "BLOCKED: $path is not checked out." >&2; blocked=1; continue; }
    branch="$(sm_branch "$path")"
    if [ -z "$branch" ]; then
      echo "BLOCKED: $path is in detached HEAD." >&2
      blocked=1
      continue
    fi
    if path_is_dirty "$path"; then
      echo "BLOCKED: $path has uncommitted changes. Commit first." >&2
      blocked=1
      continue
    fi
    if [ "$path" = "." ]; then
      local gitlinks
      gitlinks="$(super_uncommitted_gitlinks)"
      if [ -n "$gitlinks" ]; then
        echo "BLOCKED: superproject has uncommitted submodule pointer update(s): $(echo "$gitlinks" | paste -sd ' ' -). Commit them first, otherwise the superproject's PR would reference the old submodule commits." >&2
        blocked=1
        continue
      fi
    fi
    if [ "$branch" = "$base_branch" ]; then
      skip_notes+=("$path: on $base_branch itself, nothing to PR")
      continue
    fi
    local ab ahead behind
    if ! ab="$(sm_ahead_behind "$path" "$branch")"; then
      echo "BLOCKED: $path — branch '$branch' has no origin/$branch. Push it first (scripts/sync.sh push)." >&2
      blocked=1
      continue
    fi
    ahead="$(echo "$ab" | awk '{print $1}')"
    behind="$(echo "$ab" | awk '{print $2}')"
    if [ "$ahead" -gt 0 ]; then
      echo "BLOCKED: $path — $ahead unpushed commit(s) on $branch. Run scripts/sync.sh push first." >&2
      blocked=1
      continue
    fi
    if [ "$behind" -gt 0 ]; then
      echo "BLOCKED: $path — $branch is behind its own origin/$branch by $behind commit(s). Run scripts/sync.sh pull first." >&2
      blocked=1
      continue
    fi
    if ! fetch_branch "$path" "$base_branch"; then
      echo "BLOCKED: $path — origin/$base_branch not found (fetch failed)." >&2
      blocked=1
      continue
    fi
    if ! gh_in "$path" repo view --json nameWithOwner >/dev/null 2>&1; then
      echo "BLOCKED: $path — gh can't resolve a GitHub repo from its remotes (not a GitHub remote, or no access)." >&2
      blocked=1
      continue
    fi
    # `gh pr view <branch>` also returns closed/merged PRs for that branch;
    # only an OPEN one means "already has a PR".
    local existing
    existing="$(gh_in "$path" pr view "$branch" --json url,state -q 'select(.state == "OPEN") | .url' 2>/dev/null || true)"
    if [ -n "$existing" ]; then
      skip_notes+=("$path: PR already exists — $existing")
      continue
    fi
    local -a subjects=()
    local line
    while IFS= read -r line; do
      [ -n "$line" ] && subjects+=("$line")
    done < <(git -C "$path" log --reverse --format='%s' "origin/$base_branch..$branch")
    if [ "${#subjects[@]}" -eq 0 ]; then
      skip_notes+=("$path: no commits ahead of origin/$base_branch, nothing to PR")
      continue
    fi
    local title body
    if [ "${#subjects[@]}" -eq 1 ]; then
      title="${subjects[0]}"
    else
      title="$branch"
    fi
    body="$(printf -- '- %s\n' "${subjects[@]}")"
    pr_paths+=("$path")
    pr_branches+=("$branch")
    pr_titles+=("$title")
    pr_bodies+=("$body")
  done < <(all_paths)

  if [ "$blocked" -ne 0 ]; then
    echo
    echo "Nothing created. Fix the BLOCKED items above and re-run." >&2
    return 2
  fi

  local note
  for note in "${skip_notes[@]:-}"; do
    [ -n "$note" ] && echo "SKIP: $note"
  done

  if [ "${#pr_paths[@]}" -eq 0 ]; then
    echo
    echo "Nothing to open — no repo has unmerged commits without an existing PR."
    return 0
  fi

  local i
  for i in "${!pr_paths[@]}"; do
    echo "PLAN: ${pr_paths[$i]} — ${pr_branches[$i]} -> $base_branch: \"${pr_titles[$i]}\""
    echo "${pr_bodies[$i]}" | sed 's/^/    /'
  done

  if [ "$dry_run" -eq 1 ]; then
    echo
    echo "(dry run — no PR created)"
    return 0
  fi

  local -a created_urls=() draft_flag=()
  [ "$draft" -eq 1 ] && draft_flag=(--draft)
  local url
  for i in "${!pr_paths[@]}"; do
    path="${pr_paths[$i]}"
    echo "-- opening PR for $path --"
    # ${arr[@]+...}: bash 3.2 (macOS default) treats an empty array as unbound under `set -u`.
    if ! url="$(gh_in "$path" pr create --base "$base_branch" --head "${pr_branches[$i]}" --title "${pr_titles[$i]}" --body "${pr_bodies[$i]}" ${draft_flag[@]+"${draft_flag[@]}"})"; then
      echo "BLOCKED: $path — gh pr create failed. Already opened: ${created_urls[*]:-<none>}. Stopping — remaining repos were not touched." >&2
      return 2
    fi
    created_urls+=("$url")
    echo "$url"
  done

  echo
  echo "Done. Opened PR(s):"
  printf '  %s\n' "${created_urls[@]}"
}

# --- main --------------------------------------------------------------

case "${1:-}" in
  status) cmd_status ;;
  pull) cmd_pull ;;
  push) shift; cmd_push "${1:-}" ;;
  merge-base) shift; cmd_merge_base "$@" ;;
  pr) shift; cmd_pr "$@" ;;
  *)
    echo "Usage: $0 {status|pull|push [--dry-run]|merge-base <base-branch>|pr <base-branch> [--dry-run] [--draft]}" >&2
    exit 1
    ;;
esac
