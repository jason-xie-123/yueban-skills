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
#       changed for pull, and nothing was pushed for push (unless a push itself
#       failed midway — stderr lists what was already pushed). For merge-base,
#       everything up to (not including) the first conflicting repo was
#       already merged; for pr, every PR before the first failed
#       `gh pr create` was already opened — see stderr for exactly which ones.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$REPO_ROOT" || exit 1

# Run inside a submodule, every command would treat that one submodule as the
# whole project (and push or merge it alone). A repo that has its own
# .gitmodules is a superproject even if it is nested in another one.
SUPER_ROOT="$(git rev-parse --show-superproject-working-tree 2>/dev/null)"
if [ -n "$SUPER_ROOT" ] && [ ! -f .gitmodules ]; then
  echo "BLOCKED: this is a submodule ($REPO_ROOT). Run this from its superproject: $SUPER_ROOT" >&2
  exit 2
fi

# --- helpers -----------------------------------------------------------

list_submodules() {
  # Active submodules only: paths under deprecated/ are intentionally out of
  # scope (see SKILL.md) — they don't need to stay in lockstep across machines.
  # -z output is "<key>\n<value>\0", so paths with spaces survive.
  local entry path
  git config -z -f .gitmodules --get-regexp '\.path$' 2>/dev/null \
    | while IFS= read -r -d '' entry; do
        path="${entry#*$'\n'}"
        case "$path" in deprecated/*) continue ;; esac
        printf '%s\n' "$path"
      done
}

# True if $1 is a repo checked out in its own right ("." always is). An
# uninitialised submodule is an empty directory, where `git -C` silently finds
# the superproject instead: every check, merge and push would hit the wrong repo.
sm_present() {
  [ "$1" = "." ] && return 0
  [ -e "$1/.git" ] || return 1
  [ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$1" && pwd -P)" ]
}

missing_msg() {
  echo "$1 is not checked out (an uninitialised submodule) — initialise it first (e.g. git submodule update --init $1, or the project's own worktree setup) and put it on the superproject's branch, then re-run."
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
# Only active submodules count: deprecated/ ones are out of scope.
super_uncommitted_gitlinks() {
  local active p
  active="$(list_submodules)"
  git diff --name-only --ignore-submodules=dirty HEAD 2>/dev/null \
    | while IFS= read -r p; do
        printf '%s\n' "$active" | grep -qxF -- "$p" && printf '%s\n' "$p"
      done
}

# True if submodule commit $2 will be on $1's origin once this push is done:
# either it is reachable from the submodule HEAD that push sends (or that is
# already up to date on origin), or a branch on origin contains it. Only
# origin counts (a fork is not where clones fetch from); callers prune-fetch
# first, so a branch deleted on origin no longer counts.
gitlink_published() {
  git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null || return 1
  git -C "$1" merge-base --is-ancestor "$2" HEAD 2>/dev/null && return 0
  [ -n "$(git -C "$1" for-each-ref --contains "$2" refs/remotes/origin 2>/dev/null)" ]
}

# Prints "<tip|history> <superproject commit> <submodule path> <recorded sha>"
# for every submodule pointer recorded by the superproject commits in
# origin/<branch>..HEAD that would not be on the submodule's remote after this
# push — e.g. the submodule commit was amended or reset after the pointer was
# recorded. "tip" means HEAD records it, so clones of the pushed branch can't
# check the submodule out; "history" means only an older commit in the range
# does, which only breaks checking out that commit (bisect, reverts).
# Pointers equal to what origin/<branch> already records are not re-checked.
# On a branch's first push the range is every commit not yet on origin.
unpublished_gitlinks() {
  local super_branch="$1" path c sha old seen fetched where head
  local -a range
  head="$(git rev-parse HEAD)"
  if git rev-parse -q --verify "refs/remotes/origin/$super_branch" >/dev/null; then
    range=("origin/$super_branch..HEAD")
  else
    range=(HEAD --not --remotes=origin)
  fi
  while IFS= read -r path; do
    sm_present "$path" || continue
    seen=" "; fetched=0
    old="$(git rev-parse -q --verify "origin/$super_branch:$path" 2>/dev/null || true)"
    while IFS= read -r c; do
      sha="$(git rev-parse -q --verify "$c:$path" 2>/dev/null)" || continue
      [ "$sha" = "$old" ] && continue
      case "$seen" in *" $sha "*) continue ;; esac
      seen="$seen$sha "
      git -C "$path" merge-base --is-ancestor "$sha" HEAD 2>/dev/null && continue
      if [ "$fetched" -eq 0 ]; then
        # Remote-tracking refs may be stale or deleted on origin: prune-fetch
        # once before trusting them.
        git -C "$path" fetch --quiet --prune origin 2>/dev/null || true
        fetched=1
      fi
      gitlink_published "$path" "$sha" && continue
      where=history; [ "$c" = "$head" ] && where=tip
      echo "$where ${c:0:8} $path ${sha:0:8}"
    done < <(git rev-list "${range[@]}")
  done < <(list_submodules)
}

# Run gh inside a repo directory — gh has no `-C` flag like git does.
gh_in() {
  local path="$1"; shift
  (cd "$path" && gh "$@")
}

# Submodules must sit on the same branch name as the superproject: that is the
# pairing yueban-git-feature-branch-flow sets up (every repo on <change-id>, or
# every repo on the base branch). A mismatch — e.g. superproject on a feature
# branch while submodules stay on develop — means pulls/pushes/merges/PRs land
# on a different branch than the superproject's recorded pointers belong to.
# Prints a BLOCKED line and returns 1 on mismatch; detached/missing submodules
# are reported by the callers' own checks, not here.
check_branch_matches_super() {
  local path="$1" branch="$2" super_branch="$3"
  [ "$path" = "." ] && return 0
  [ -z "$branch" ] || [ -z "$super_branch" ] && return 0
  [ "$branch" = "$super_branch" ] && return 0
  echo "BLOCKED: $path is on '$branch' but the superproject is on '$super_branch'. Submodules must be on the same branch as the superproject — check out '$super_branch' in $path by hand (or switch the superproject), then re-run. This tool will not pick one for you." >&2
  return 1
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
  local super_branch
  super_branch="$(sm_branch ".")"
  local -a mismatched=()
  while IFS= read -r path; do
    if ! sm_present "$path"; then
      echo "  $path: MISSING (not checked out — uninitialised submodule)"
      mismatched+=("$path (not checked out)")
      continue
    fi
    branch="$(sm_branch "$path")"
    dirty="clean"; sm_is_dirty "$path" && dirty="DIRTY"
    rec="$(sm_recorded_sha "$path")"
    head="$(sm_head_sha "$path")"
    printf '  %s: branch=%s %s' "$path" "${branch:-<DETACHED>}" "$dirty"
    if [ -n "$branch" ] && [ -n "$super_branch" ] && [ "$branch" != "$super_branch" ]; then
      printf ' [BRANCH MISMATCH: superproject=%s]' "$super_branch"
      mismatched+=("$path ($branch)")
    elif [ -z "$branch" ]; then
      mismatched+=("$path (detached HEAD)")
    fi
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
  echo
  if [ -z "$super_branch" ]; then
    echo "BRANCH CHECK: superproject is in detached HEAD — cannot compare branch names."
  elif [ "${#mismatched[@]}" -gt 0 ]; then
    echo "BRANCH MISMATCH: superproject is on '$super_branch', but these submodules are not: ${mismatched[*]}. pull/push/merge-base/pr will refuse to run until they match."
  else
    echo "BRANCH CHECK: OK — superproject and every submodule are on '$super_branch'."
  fi
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
    sm_present "$path" || { echo "BLOCKED: $(missing_msg "$path")" >&2; blocked=1; continue; }
    branch="$(sm_branch "$path")"
    if [ -z "$branch" ]; then
      echo "BLOCKED: $path is already in detached HEAD. Resolve manually first (checkout the intended branch) — this tool will not guess which branch you meant." >&2
      blocked=1
      continue
    fi
    check_branch_matches_super "$path" "$branch" "$super_branch" || { blocked=1; continue; }
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
      git -c submodule.recurse=false merge --ff-only "origin/$super_branch" || return 2
  else
    echo "Already up to date."
  fi

  local i
  for i in "${!paths[@]}"; do
    path="${paths[$i]}"; branch="${branches[$i]}"
    echo "-- $path: fast-forwarding $branch to origin/$branch --"
    run_step "$path: fast-forward of $branch failed unexpectedly. The superproject was already pulled; resolve $path by hand, then re-run." \
      git -C "$path" -c submodule.recurse=false merge --ff-only "origin/$branch" || return 2
  done

  echo
  echo "Done. Every submodule stayed on its branch (no detached HEAD)."
  cmd_status
}

# --- push ------------------------------------------------------------------

# Pushes $1's HEAD to origin/<$2>, by name rather than through the branch's
# upstream: a branch created from origin/develop tracks develop, and a plain
# `git push` would then refuse, or with push.default=upstream publish the
# feature branch onto develop. -u only when no upstream is configured, so an
# existing one is never rewritten.
push_head() {
  local -a u=()
  git -C "$1" config --get "branch.$2.merge" >/dev/null 2>&1 || u=(-u)
  git -C "$1" push ${u[@]+"${u[@]}"} origin "HEAD:refs/heads/$2"
}

# Prints "AHEAD BEHIND NEW" for $1 on branch $2: NEW is 1 when origin has no
# such branch yet (first push), and AHEAD then counts commits not on origin at all.
push_counts() {
  local ab
  if ab="$(sm_ahead_behind "$1" "$2")"; then
    echo "$ab 0"
  else
    echo "$(git -C "$1" rev-list --count HEAD --not --remotes=origin 2>/dev/null || echo 0) 0 1"
  fi
}

cmd_push() {
  local dry_run=0
  case "${1:-}" in
    "") ;;
    --dry-run) dry_run=1 ;;
    *) echo "Usage: $0 push [--dry-run]" >&2; return 1 ;;
  esac

  local -a push_paths=() push_branches=()
  local path branch
  local blocked=0
  local super_ahead super_behind super_new

  # Same divergence check cmd_pull does for the superproject, so a failing
  # push isn't the first time we notice the superproject is behind — we
  # report it alongside the other BLOCKED items instead of failing mid-push
  # after submodules already went out.
  local super_branch
  super_branch="$(sm_branch ".")"
  if [ -z "$super_branch" ]; then
    echo "BLOCKED: superproject is in detached HEAD. Resolve manually first (checkout the intended branch)." >&2
    return 2
  fi
  read -r super_ahead super_behind super_new < <(push_counts "." "$super_branch")
  if [ "$super_behind" -gt 0 ]; then
    echo "BLOCKED: superproject ($super_branch) is behind origin/$super_branch by $super_behind commit(s) (ahead $super_ahead). Pull first — this tool never force-pushes." >&2
    blocked=1
  fi

  while IFS= read -r path; do
    sm_present "$path" || { echo "BLOCKED: $(missing_msg "$path")" >&2; blocked=1; continue; }
    branch="$(sm_branch "$path")"
    if [ -z "$branch" ]; then
      echo "BLOCKED: $path is in detached HEAD — its commits aren't on any branch, so they can't be safely pushed. Resolve manually." >&2
      blocked=1
      continue
    fi
    check_branch_matches_super "$path" "$branch" "$super_branch" || { blocked=1; continue; }
    if sm_is_dirty "$path"; then
      echo "BLOCKED: $path has uncommitted changes. Commit inside the submodule first." >&2
      blocked=1
      continue
    fi
    local ahead behind new
    read -r ahead behind new < <(push_counts "$path" "$branch")
    if [ "$behind" -gt 0 ]; then
      echo "BLOCKED: $path ($branch) is behind origin/$branch by $behind commit(s) (ahead $ahead). Pull first — this tool never force-pushes." >&2
      blocked=1
      continue
    fi
    if [ "$new" -eq 1 ]; then
      echo "PLAN: $path — first push: create origin/$branch ($ahead commit(s) not on origin yet)"
      push_paths+=("$path")
      push_branches+=("$branch")
    elif [ "$ahead" -gt 0 ]; then
      echo "PLAN: $path — push $ahead commit(s) to origin/$branch"
      push_paths+=("$path")
      push_branches+=("$branch")
    else
      echo "PLAN: $path — up to date, nothing to push"
    fi
    local rec head
    rec="$(sm_recorded_sha "$path")"; head="$(sm_head_sha "$path")"
    if [ -n "$rec" ] && [ "$rec" != "$head" ]; then
      echo "NOTE: $path is at ${head:0:8} but the superproject's HEAD records ${rec:0:8} — the superproject push will not reference the newer submodule commits until that pointer is committed."
    fi
  done < <(list_submodules)

  if [ "$blocked" -eq 0 ]; then
    local uwhere ucommit upath usha
    while read -r uwhere ucommit upath usha; do
      [ -n "$usha" ] || continue
      if [ "$uwhere" = history ]; then
        echo "NOTE: older superproject commit $ucommit (not the tip being pushed) records $upath at $usha, which is not on $upath's remote — checking out that commit later (bisect, revert) can't fetch the submodule. The pushed tip is fine."
        continue
      fi
      echo "BLOCKED: superproject commit $ucommit (the tip being pushed) records $upath at $usha, which is neither on $upath's remote nor in the $upath branch this push sends (e.g. the submodule commit was amended or reset after the pointer was recorded). Pushing it would leave a pointer nobody can fetch. Commit the submodule's current pointer in the superproject, or push $usha inside $upath, then re-run." >&2
      blocked=1
    done < <(unpublished_gitlinks "$super_branch")
  fi

  if [ "$blocked" -ne 0 ]; then
    echo
    echo "Nothing pushed. Fix the BLOCKED items above and re-run." >&2
    return 2
  fi

  if [ "$super_new" -eq 1 ]; then
    echo "PLAN: superproject — first push: create origin/$super_branch ($super_ahead commit(s) not on origin yet), after the submodules"
  elif [ "$super_ahead" -gt 0 ]; then
    echo "PLAN: superproject — push $super_ahead commit(s) to origin/$super_branch"
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
      push_head "$path" "$branch" || return 2
    pushed_paths+=("$path")
  done

  if [ "$super_new" -eq 1 ] || [ "$super_ahead" -gt 0 ]; then
    echo "-- pushing superproject ($super_branch) --"
    run_step "superproject push failed. All submodule commits above were already pushed to their own remotes; resolve the superproject by hand, then re-run (the submodule pushes will just report 'up to date')." \
      push_head "." "$super_branch" || return 2
  fi

  echo
  echo "Done. Submodule commits were pushed before the superproject, and every pointer the pushed superproject tip records was checked to exist on its submodule's remote."
}

# --- merge-base --------------------------------------------------------

# Every active submodule, then the superproject (".") last — used by
# merge-base and pr. Submodules come first because the superproject's merge
# (and PR) has to record the submodule commits that exist once those are done.
all_paths() {
  list_submodules
  echo "."
}

# Merges origin/<base> into the superproject. When the base side moved a
# submodule pointer, git records the base's commit or stops on a gitlink
# conflict — neither includes the submodule merge this command just made. So
# for every such path whose submodule HEAD contains both sides' recorded
# commits, the pointer is set to that HEAD before committing. Pointers only
# our side moved are left as recorded: the submodule may hold further commits
# the user hasn't chosen to record. A fast-forward records the base's pointers
# as they are (pointer lag, see SKILL.md).
# Returns 0 when merged (or fast-forwarded), 1 when git refused to start, 3 when
# conflicts remain (repo left mid-merge, resolvable gitlinks already set), 4
# when the merge commit itself failed (e.g. a hook rejected it).
merge_superproject() {
  local base="$1" p ours theirs mb_rec head ok s mb
  if git -c submodule.recurse=false merge --no-edit --no-commit "origin/$base"; then
    git rev-parse -q --verify MERGE_HEAD >/dev/null || return 0
  else
    git rev-parse -q --verify MERGE_HEAD >/dev/null || return 1
  fi
  mb="$(git merge-base HEAD MERGE_HEAD 2>/dev/null || true)"
  while IFS= read -r p; do
    sm_present "$p" || continue
    ours="$(git rev-parse -q --verify "HEAD:$p" 2>/dev/null || true)"
    theirs="$(git rev-parse -q --verify "MERGE_HEAD:$p" 2>/dev/null || true)"
    mb_rec=""
    [ -n "$mb" ] && mb_rec="$(git rev-parse -q --verify "$mb:$p" 2>/dev/null || true)"
    [ "$ours" != "$theirs" ] || continue
    [ "$theirs" != "$mb_rec" ] || continue
    head="$(sm_head_sha "$p")"
    [ -n "$head" ] || continue
    ok=1
    for s in "$ours" "$theirs"; do
      [ -z "$s" ] && continue
      git -C "$p" merge-base --is-ancestor "$s" "$head" 2>/dev/null || ok=0
    done
    if [ "$ok" -eq 1 ]; then
      git update-index --cacheinfo "160000,$head,$p" || return 3
      echo "   $p: recording ${head:0:8} (contains both sides' pointers)"
    fi
  done < <(list_submodules)
  [ -z "$(git diff --name-only --diff-filter=U)" ] || return 3
  git commit --no-edit --quiet || return 4
  return 0
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
  local super_branch
  super_branch="$(sm_branch ".")"

  while IFS= read -r path; do
    sm_present "$path" || { echo "BLOCKED: $(missing_msg "$path")" >&2; blocked=1; continue; }
    branch="$(sm_branch "$path")"
    if [ -z "$branch" ]; then
      echo "BLOCKED: $path is in detached HEAD. Resolve manually first (checkout the intended branch)." >&2
      blocked=1
      continue
    fi
    check_branch_matches_super "$path" "$branch" "$super_branch" || { blocked=1; continue; }
    if git -C "$path" rev-parse -q --verify MERGE_HEAD >/dev/null; then
      echo "BLOCKED: $path has a merge in progress. Finish it (\`git -C $path commit\`) or cancel it (\`git -C $path merge --abort\`) first — this tool won't commit a merge it didn't start." >&2
      blocked=1
      continue
    fi
    if path_is_dirty "$path"; then
      echo "BLOCKED: $path has uncommitted changes. Commit or stash first." >&2
      blocked=1
      continue
    fi
    # With check_branch_matches_super above, this only fires when every repo
    # (superproject included) is on the base branch itself.
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
    local rc=0
    if [ "$path" = "." ]; then
      merge_superproject "$base_branch" || rc=$?
    else
      # --no-edit: take git's default merge message instead of opening an
      # editor when run from an interactive terminal.
      if ! git -C "$path" -c submodule.recurse=false merge --no-edit origin/"$base_branch"; then
        rc=3
        git -C "$path" rev-parse -q --verify MERGE_HEAD >/dev/null || rc=1
      fi
    fi
    if [ "$rc" -eq 4 ]; then
      echo "BLOCKED: $path — the merge of origin/$base_branch into $branch has no conflicts left but \`git commit\` failed (see git's message above, e.g. a hook). The repo is left mid-merge: fix that and run \`git -C $path commit --no-edit\`, or \`git -C $path merge --abort\`. Already merged before this: ${merged_paths[*]:-<none>}." >&2
      return 2
    fi
    if [ "$rc" -eq 1 ]; then
      echo "BLOCKED: $path — merge of origin/$base_branch into $branch failed before starting (see git's message above); $path was not changed. Already merged before this: ${merged_paths[*]:-<none>}. Stopping — remaining repos were not touched." >&2
      return 2
    fi
    if [ "$rc" -ne 0 ]; then
      local hint=""
      if [ "$path" = "." ]; then
        hint=" Submodule pointers whose submodule HEAD contains both sides were already set to that HEAD. For a gitlink still in conflict, the submodule's HEAD lacks one side's commit: merge that commit into the submodule's branch, then record it with \`git update-index --cacheinfo 160000,<sha>,<submodule-path>\` (not \`git add\` before the submodule merge, which would record a pointer without the base branch's submodule changes)."
      else
        hint=" The superproject was not merged yet: once this repo is resolved and committed, re-run this command — it skips repos already up to date and merges the superproject last."
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
  local super_branch
  super_branch="$(sm_branch ".")"

  while IFS= read -r path; do
    sm_present "$path" || { echo "BLOCKED: $(missing_msg "$path")" >&2; blocked=1; continue; }
    branch="$(sm_branch "$path")"
    if [ -z "$branch" ]; then
      echo "BLOCKED: $path is in detached HEAD." >&2
      blocked=1
      continue
    fi
    check_branch_matches_super "$path" "$branch" "$super_branch" || { blocked=1; continue; }
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
    # Same as merge-base: only reachable when every repo is on the base branch.
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
    done < <(git -C "$path" log --no-merges --reverse --format='%s' "origin/$base_branch..$branch")
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
