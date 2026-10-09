#!/usr/bin/env bash
# wt.sh — git worktree plumbing for yueban-spec-simple-worktree-single-change-flow (and the roadmap flow that
# runs several of them in parallel): give one OpenSpec change its own worktree + branch off a base branch, then
# land the finished branch back onto the base as a fast-forward, serialized by a repo-wide lock so parallel
# changes never race on the base branch. See ../SKILL.md for the workflow this script serves.
#
# Usage:
#   wt.sh start     <change> [--base <branch>]   Create (or reuse) <main worktree>/.worktrees/<change> on branch
#                                                spec/<change>. Base defaults to the current branch. Prints STATE=
#                                                (new / in_progress / archived / integrated / rebasing / merging)
#                                                and SUBMODULE_ON_BRANCH= for each submodule that lands with it.
#   wt.sh integrate                              Run inside the change worktree: fast-forward the base branch to
#                                                this branch. Exits 3 when the branch must catch up with the
#                                                base first (NEEDS_REBASE / NEEDS_MERGE).
#   wt.sh cleanup   <change>                     Run outside the change worktree, after integrate: remove the
#                                                worktree and delete spec/<change> (in the main worktree's
#                                                submodules too).
#   wt.sh landed    <change> [--base <branch>]   Read-only: is the change archived on the base branch?
#                                                Prints LANDED=yes / no / unknown.
#   wt.sh lock      [--wait <seconds>]           Take the integration lock (to commit on the base branch outside
#                                                integrate, e.g. ROADMAP.md). Prints LOCK_TOKEN=<token>.
#   wt.sh unlock    <token>                      Release a lock taken with 'lock'; refuses another holder's lock.
#   wt.sh status                                 List spec/* branches: worktree, state, ahead/behind, dirty.
#
# Lines starting with KEY=value on stdout are meant to be read back (WORKTREE=, BRANCH=, BASE=, STATE=, HEAD=, ...).
# integrate and lock wait up to 540s for the lock: call them with a Bash timeout of at least 600s.
#
# Project hooks: a committed .yueban/config (git config syntax) can name a command to run after start creates or
# reuses a worktree and one to run before cleanup removes it. start refuses to run when the main worktree has the
# file but the base does not (not committed yet):
#   [worktree]
#       setup = <command>      run on every start, so it must be safe to run again; replaces the built-in
#                              'git submodule update --init'
#       teardown = <command>   run by cleanup before the worktree is removed (and by start to undo a failed
#                              setup); a failure removes nothing. Must also be safe to run again. Skipped
#                              when the worktree directory is already gone
#       protect = <branches>   space-separated branches start refuses as a base (e.g. shared integration
#                              branches the change must reach through review, not a local fast-forward)
# Both run through bash in the change worktree with YUEBAN_WT_PATH, YUEBAN_WT_BRANCH, YUEBAN_WT_BASE, YUEBAN_CHANGE
# and YUEBAN_MAIN_WT set; their output goes to stderr.
#
# Submodules: a submodule the change modifies lands with it when, in the change worktree, it is on spec/<change>
# and is a worktree of the same repository as the main worktree's submodule (a setup hook can arrange both).
# integrate then fast-forwards the submodule's branch named like the base before the parent's base, and undoes
# those moves if the parent's fails. Such a branch catches up with its base by merging, not rebasing (NEEDS_MERGE).
#
# Integration lock (a contract other tools can rely on): the directory <git common dir>/yueban-spec-integrate.lock
# of the parent repository, taken with an atomic mkdir and released by removing it. Its holder writes an owner file
# whose first line starts with 'token=<token> pid=<pid> ' (pid left empty by 'lock', whose lock is never taken
# over); the rest of the line is for people. Any other tool that fast-forwards or commits on a branch integrate may
# move (the base in the parent, or the branch of the same name in a submodule) must hold this lock, the same way,
# while it does so; then it and integrate never move that branch at once. A waiter takes over a lock whose pid no
# longer runs: under <lock>.takeover (a directory taken with mkdir), it removes the lock only while the owner line is
# still the dead holder's. Taking over repairs nothing a dead holder left half done; integrate refuses a base
# worktree left out of step.
#
# Exit codes:
#   0 = done (integrate also exits 0 with ALREADY_INTEGRATED when there is nothing left to land)
#   1 = usage error
#   2 = BLOCKED: report the message to the user; nothing was changed unless the message says otherwise
#   3 = integrate only: base moved on. NEEDS_REBASE: rebase onto it; NEEDS_MERGE (the branch changes submodules):
#       merge it into every repository listed in SYNC_REPO= lines. Then re-test and integrate again.

set -uo pipefail

# Seconds integrate/lock wait for the lock: below the 600s ceiling of agent Bash tools, so the script reports
# BLOCKED itself instead of being killed. YUEBAN_WT_LOCK_WAIT overrides it (selftest uses this).
LOCK_WAIT_DEFAULT="${YUEBAN_WT_LOCK_WAIT:-540}"
is_seconds() { printf '%s' "$1" | grep -Eq '^[0-9]{1,6}$'; }
is_seconds "${LOCK_WAIT_DEFAULT}" || { echo "YUEBAN_WT_LOCK_WAIT must be a number of seconds (at most 6 digits)" >&2; exit 1; }
case "${1:-}" in -h|--help|"") awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"; [ -n "${1:-}" ]; exit ;; esac
# Read-only status calls must not take index.lock: that would make a concurrent commit or ff-merge fail.
export GIT_OPTIONAL_LOCKS=0

die()     { echo "$*" >&2; exit 1; }
blocked() { echo "BLOCKED: $*" >&2; exit 2; }

git rev-parse --git-dir >/dev/null 2>&1 || die "Not inside a git repository."
[ "$(git rev-parse --is-bare-repository)" = false ] || die "Run this in a (non-bare) worktree of the repository."
git worktree list --porcelain | awk 'NR==2{exit ($0=="bare") ? 0 : 1}' \
  && { echo "BLOCKED: the main worktree of this repository is bare; .worktrees/ needs a normal main worktree." >&2; exit 2; }
# set_ctx: COMMON_DIR and MAIN_WT of the repository in the current directory (re-run inside a subshell to work on
# a submodule's repository). The main worktree is always listed first; .worktrees/ lives there even when called
# from a linked worktree.
set_ctx() {
  COMMON_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  MAIN_WT="$(real_wt "$(git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')")"
}
# real_wt <path>: a worktree path as 'git worktree list' prints it. A submodule's main worktree is listed as its git
# dir (.git/modules/<name>, whose core.worktree points at the checkout); that one is resolved to the checkout.
real_wt() {
  local w
  if [ -n "$1" ] && [ -f "$1/HEAD" ] && [ ! -e "$1/.git" ] && w="$(git --git-dir="$1" config --get core.worktree 2>/dev/null)"; then
    case "${w}" in /*) ;; *) w="$1/${w}" ;; esac
    (cd "${w}" 2>/dev/null && pwd -P) || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}
set_ctx
LOCK_DIR="${COMMON_DIR}/yueban-spec-integrate.lock"

current_branch() { git symbolic-ref -q --short HEAD || true; }
rev()            { git rev-parse -q --verify "refs/heads/$1^{commit}"; }
# Untracked files inside submodules (build output) don't count; everything else does.
is_dirty()       { [ -n "$(git -C "$1" status --porcelain --ignore-submodules=untracked 2>/dev/null)" ]; }
# Tracked changes only: an ff merge refuses on its own if it would overwrite an untracked file.
is_dirty_tracked() { [ -n "$(git -C "$1" status --porcelain --untracked-files=no --ignore-submodules=untracked 2>/dev/null)" ]; }
branch_exists()  { [ "$(git for-each-ref --format='%(refname)' "refs/heads/$1")" = "refs/heads/$1" ]; }
base_of()        { git config --get "branch.$1.yuebanSpecBase" || true; }
is_ancestor()    { git merge-base --is-ancestor "$1" "$2" 2>/dev/null; }
physical()       { (cd "$1" 2>/dev/null && pwd -P); }

in_list()        { local x="$1" y; shift; for y in "$@"; do [ "${y}" = "${x}" ] && return 0; done; return 1; }
merging_in()     { (cd "$1" 2>/dev/null && [ -f "$(git rev-parse --git-path MERGE_HEAD)" ]); }
common_dir_of() { (cd "$1" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P); }

# --- project hooks ----------------------------------------------------------

# hook_cmd <worktree> <setup|teardown>: the configured command (empty when none); fails on an unreadable config.
hook_cmd() {
  local f="$1/.yueban/config" out rc
  [ -f "${f}" ] || return 0
  out="$(git config -f "${f}" --get "worktree.$2" 2>&1)"; rc=$?
  case "${rc}" in
    0) printf '%s' "${out}" ;;
    1) ;;
    *) echo "cannot read ${f}: ${out}" >&2; return 1 ;;
  esac
}

# protected_base <branch>: whether the main worktree's .yueban/config lists <branch> in worktree.protect.
protected_base() {
  local b list=()
  read -r -a list <<< "$(hook_cmd "${MAIN_WT}" protect 2>/dev/null)"
  for b in ${list[@]+"${list[@]}"}; do [ "${b}" = "$1" ] && return 0; done
  return 1
}

# run_hook <setup|teardown> <worktree> <branch> <base>: 0 when no hook is configured or it succeeded.
run_hook() {
  local cmd
  cmd="$(hook_cmd "$2" "$1")" || return 1
  [ -n "${cmd}" ] || return 0
  echo "HOOK $1: ${cmd}" >&2
  ( cd "$2" && env -u GIT_OPTIONAL_LOCKS YUEBAN_WT_PATH="$2" YUEBAN_WT_BRANCH="$3" YUEBAN_WT_BASE="$4" \
      YUEBAN_CHANGE="${3#spec/}" YUEBAN_MAIN_WT="${MAIN_WT}" bash -c "${cmd}" ) </dev/null >&2
}

# --- submodules -------------------------------------------------------------

# submodule_paths <worktree>: the paths listed in <worktree>/.gitmodules, one per line.
submodule_paths() {
  [ -f "$1/.gitmodules" ] || return 0
  local rec
  # -z: names and paths may contain spaces; each record is "<key>\n<value>".
  while IFS= read -r -d '' rec; do printf '%s\n' "${rec#*$'\n'}"; done \
    < <(git config -z -f "$1/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null)
}

# branch_submodules <worktree> <branch>: the checked-out submodules of <worktree> that are on <branch>.
branch_submodules() {
  local p
  while IFS= read -r p; do
    [ -n "${p}" ] && [ -e "$1/${p}/.git" ] || continue
    [ "$(git -C "$1/${p}" symbolic-ref -q --short HEAD 2>/dev/null)" = "$2" ] && printf '%s\n' "${p}"
  done < <(submodule_paths "$1")
}

# dirty_beyond_removed_submodules <worktree>: its status entries, minus submodules whose checkout is gone (a
# teardown hook that failed halfway may already have removed some; only used when a teardown hook exists, since
# without one a submodule's git dir may live inside the worktree); empty when nothing else is dirty.
dirty_beyond_removed_submodules() {
  local entry p subs
  subs="$(submodule_paths "$1")"
  while IFS= read -r -d '' entry; do
    p="${entry:3}"
    if [ "${entry:0:3}" = " D " ] && [ ! -e "$1/${p}" ] && printf '%s\n' "${subs}" | grep -qxF -- "${p}"; then continue; fi
    printf '%s\n' "${entry}"
  done < <(git -C "$1" status --porcelain -z --ignore-submodules=untracked 2>/dev/null)
}

# drop_submodule_branches <branch>: deletes <branch> in the main worktree's submodules (after a failed start, which
# checked that none had it before).
drop_submodule_branches() {
  local p
  while IFS= read -r p; do
    [ -n "${p}" ] && [ -e "${MAIN_WT}/${p}/.git" ] || continue
    git -C "${MAIN_WT}/${p}" worktree prune 2>/dev/null
    git -C "${MAIN_WT}/${p}" show-ref --verify -q "refs/heads/$1" && git -C "${MAIN_WT}/${p}" branch -q -D "$1" 2>/dev/null
  done < <(submodule_paths "${MAIN_WT}")
  return 0
}

# leftover_submodule_branch <branch>: the first submodule of the main worktree whose repository already has <branch>.
leftover_submodule_branch() {
  local p
  while IFS= read -r p; do
    [ -n "${p}" ] && [ -e "${MAIN_WT}/${p}/.git" ] || continue
    git -C "${MAIN_WT}/${p}" show-ref --verify -q "refs/heads/$1" && { printf '%s' "${p}"; return; }
  done < <(submodule_paths "${MAIN_WT}")
}

check_change_name() {
  case "$1" in
    ''|-*|*/*|*..*|*[[:space:]]*) die "Invalid change name '$1' (no leading '-', '/', '..' or whitespace)." ;;
  esac
}

# Git dir of each worktree, with the worktree path: "<gitdir>\t<path>" (main worktree first).
worktree_gitdirs() {
  local gd
  printf '%s\t%s\n' "${COMMON_DIR}" "${MAIN_WT}"
  for gd in "${COMMON_DIR}"/worktrees/*; do
    [ -f "${gd}/gitdir" ] || continue
    printf '%s\t%s\n' "${gd}" "$(sed 's#/\.git$##' "${gd}/gitdir")"
  done
}

# Prints the worktree path where branch $1 is being rebased (HEAD detached meanwhile), or nothing.
branch_rebasing_worktree() {
  local gd path hn
  while IFS=$'\t' read -r gd path; do
    for hn in "${gd}/rebase-merge/head-name" "${gd}/rebase-apply/head-name"; do
      if [ -f "${hn}" ] && [ "$(cat "${hn}")" = "refs/heads/$1" ]; then echo "${path}"; return; fi
    done
  done < <(worktree_gitdirs)
}

# Prints the worktree path where branch $1 is being rebased or bisected, or nothing.
branch_busy_worktree() {
  local gd path
  branch_rebasing_worktree "$1"
  while IFS=$'\t' read -r gd path; do
    if [ -f "${gd}/BISECT_START" ] && [ "$(cat "${gd}/BISECT_START")" = "$1" ]; then echo "${path}"; return; fi
  done < <(worktree_gitdirs)
}

# Prints the worktree path that has branch $1 checked out, or is rebasing it, or nothing. Worktrees whose
# directory was deleted by hand are pruned first, so they never count.
branch_worktree() {
  local wt
  git worktree prune 2>/dev/null
  wt="$(git worktree list --porcelain \
    | awk -v ref="branch refs/heads/$1" '/^worktree /{w=substr($0,10)} $0==ref{print w; exit}')"
  [ -n "${wt}" ] && wt="$(real_wt "${wt}")"
  [ -n "${wt}" ] || wt="$(branch_rebasing_worktree "$1")"
  printf '%s' "${wt}"
}

# landed_state <change> <base>: yes = archived on base; no = still pending on base; unknown = neither.
landed_state() {
  if git cat-file -e "refs/heads/$2:openspec/changes/$1" 2>/dev/null; then echo no; return; fi
  if git ls-tree --name-only "refs/heads/$2" openspec/changes/archive/ 2>/dev/null \
       | grep -qE "^openspec/changes/archive/[0-9]{4}-[0-9]{2}-[0-9]{2}-$(printf '%s' "$1" | sed 's/[.[\*^$+?(){}|]/\\&/g')\$"; then
    echo yes; return
  fi
  echo unknown
}

# change_state <branch> <worktree>: the STATE start reports for an existing branch.
change_state() {
  local branch="$1" wt="$2" change="${1#spec/}" base
  base="$(base_of "${branch}")"
  if [ -n "$(branch_rebasing_worktree "${branch}")" ]; then echo rebasing; return; fi
  if [ -n "${wt}" ] && merging_in "${wt}"; then echo merging; return; fi
  if is_ancestor "refs/heads/${branch}" "refs/heads/${base}" && [ "$(landed_state "${change}" "${base}")" = yes ]; then
    echo integrated; return
  fi
  if ! git cat-file -e "refs/heads/${branch}:openspec/changes/${change}" 2>/dev/null; then echo archived; return; fi
  echo in_progress
}

config_set() { # git config can fail on a concurrent config.lock; retry briefly
  local i
  for i in 1 2 3 4 5; do git config "$@" 2>/dev/null && return 0; sleep 1; done
  git config "$@"
}

lock_acquire() { # lock_acquire <wait-seconds> <token> <label> [<pid>]
  local waited=0 owner pid
  while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
    owner="$(lock_owner)"
    pid="$(lock_pid "${owner}")"
    if [ -n "${pid}" ] && ! pid_alive "${pid}"; then
      # One waiter at a time takes over, and only while the lock still carries the dead holder's line (one taken in
      # the meantime has another line, or none yet).
      if mkdir "${LOCK_DIR}.takeover" 2>/dev/null; then
        [ "$(lock_owner)" = "${owner}" ] && rm -rf "${LOCK_DIR}"
        rmdir "${LOCK_DIR}.takeover" 2>/dev/null
        continue
      fi
      # Another waiter is taking it over; it holds the takeover directory for milliseconds, so one older than a
      # minute was left by a waiter that died inside it.
      if [ -n "$(find "${LOCK_DIR}.takeover" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        rmdir "${LOCK_DIR}.takeover" 2>/dev/null
      else
        sleep 1
      fi
      continue
    fi
    if [ "${waited}" -ge "$1" ]; then
      blocked "integration lock is still held after $1s: ${LOCK_DIR} ($(lock_describe)). If no flow is integrating or editing the base branch any more, it is stale: remove that directory and retry."
    fi
    sleep 5; waited=$((waited + 5))
  done
  printf 'token=%s pid=%s since=%s holder=%s cwd=%s\n' "$2" "${4:-}" "$(date '+%Y-%m-%d %H:%M:%S')" "$3" "$PWD" > "${LOCK_DIR}/owner"
}
# lock_describe: owner info, plus a hint when the integrate process that holds it no longer exists.
lock_describe() {
  local pid info
  info="$(lock_owner)"
  pid="$(lock_pid "${info}")"
  if [ -n "${pid}" ] && ! pid_alive "${pid}"; then info="${info}; holder process ${pid} is gone, so the lock is probably stale"; fi
  printf '%s' "${info:-no owner info}"
}
# pid_alive <pid>: kill -0 also fails for another user's process, so ps decides then.
pid_alive()  { kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1; }
lock_owner() { head -1 "${LOCK_DIR}/owner" 2>/dev/null; }
lock_pid()   { printf '%s' "$1" | sed -n 's/^token=[^ ]* pid=\([0-9][0-9]*\) .*/\1/p'; } # empty for a manual lock
lock_token() { lock_owner | sed -n 's/^token=\([^ ]*\).*/\1/p'; }
lock_release_if_mine() { [ -n "$1" ] && [ "$(lock_token)" = "$1" ] && rm -rf "${LOCK_DIR}"; return 0; }
new_token() { printf '%s-%s-%s' "$(date +%s)" "$$" "${RANDOM}${RANDOM}"; }

# --- start ------------------------------------------------------------------

# prepare_worktree <path> <branch> <base> <fresh>: runs the setup hook; without one, initializes the submodules
# of a fresh (new or re-created) worktree.
prepare_worktree() {
  local cmd
  if [ ! -f "$1/.yueban/config" ] && [ -f "${MAIN_WT}/.yueban/config" ]; then
    if ! git cat-file -e "refs/heads/$3:.yueban/config" 2>/dev/null; then
      echo "${MAIN_WT}/.yueban/config is not committed on $3, so the worktree would get no hooks; commit it on $3 first." >&2
      return 1
    fi
    echo "WARNING: $2 predates .yueban/config on $3, so no hooks ran. Catch up with $3 (rebase, or merge when submodules are involved) and run start again." >&2
  fi
  cmd="$(hook_cmd "$1" setup)" || return 1
  if [ -n "${cmd}" ]; then
    run_hook setup "$1" "$2" "$3" || return 1
  elif [ "$4" = 1 ] && [ -f "$1/.gitmodules" ]; then
    git -C "$1" submodule update --init --recursive -q \
      || echo "WARNING: submodule init failed in $1; build/test there may break." >&2
    echo "NOTE: submodules in this worktree are on detached HEADs; a change that modifies them cannot land (see 'Submodules' in wt.sh --help)." >&2
  fi
  return 0
}

# print_submodules <worktree> <branch>: SUBMODULE_ON_BRANCH=<path> for every submodule that can land with the change.
print_submodules() {
  local p
  while IFS= read -r p; do [ -n "${p}" ] && echo "SUBMODULE_ON_BRANCH=${p}"; done < <(branch_submodules "$1" "$2")
}

cmd_start() {
  local change="" base=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] && [ -n "$2" ] || die "--base needs a branch name"; base="$2"; shift 2 ;;
      --) shift; [ $# -eq 1 ] || die "Usage: wt.sh start <change> [--base <branch>]"; change="$1"; shift ;;
      -*) die "Unknown option: $1" ;;
      *) [ -z "${change}" ] || die "Only one change name."; change="$1"; shift ;;
    esac
  done
  [ -n "${change}" ] || die "Usage: wt.sh start <change> [--base <branch>]"
  check_change_name "${change}"

  local branch="spec/${change}" path="${MAIN_WT}/.worktrees/${change}" existing recorded recreated=0 sha leftover
  if [ -e "${MAIN_WT}/.worktrees" ] && [ ! -d "${MAIN_WT}/.worktrees" ]; then
    blocked "${MAIN_WT}/.worktrees exists but is not a directory."
  fi
  git -C "${MAIN_WT}" check-ignore -q ".worktrees/${change}" \
    || blocked ".worktrees/ is not git-ignored in ${MAIN_WT}. Add '.worktrees/' to .gitignore (and commit it) before creating worktrees there."

  if branch_exists "${branch}"; then
    # Reuse an earlier run: its worktree, or re-attach the branch (its commits are kept) if the directory is gone.
    recorded="$(base_of "${branch}")"
    [ -n "${recorded}" ] || blocked "branch ${branch} exists but has no recorded base (git config branch.${branch}.yuebanSpecBase <base>)."
    [ -z "${base}" ] || [ "${base}" = "${recorded}" ] \
      || blocked "${branch} was started from '${recorded}', not '${base}'. Pass --base ${recorded}, or ask the user."
    rev "${recorded}" >/dev/null || blocked "${branch}'s base '${recorded}' no longer exists."
    existing="$(branch_worktree "${branch}")"
    [ "${existing}" != "${MAIN_WT}" ] \
      || blocked "${branch} is checked out in the main worktree ${MAIN_WT}; switch it back to the base branch first."
    [ -z "${existing}" ] || [ -d "${existing}" ] \
      || blocked "${branch}'s worktree ${existing} is registered but missing (locked?); run 'git worktree unlock' / 'git worktree prune' after checking, then retry."
    if [ -z "${existing}" ]; then
      [ ! -e "${path}" ] || blocked "${path} exists but is not a worktree of ${branch}; move it away first (check it for unsaved work)."
      git worktree add -q "${path}" "${branch}" || blocked "git worktree add failed (see above)."
      existing="${path}"; recreated=1
    fi
    prepare_worktree "${existing}" "${branch}" "${recorded}" "${recreated}" \
      || blocked "preparing ${existing} failed (see above); the worktree and ${branch} are kept as they are. Fix the cause and run start again."
    echo "WORKTREE=${existing}"; echo "BRANCH=${branch}"; echo "BASE=${recorded}"
    echo "STATE=$(change_state "${branch}" "${existing}")"
    echo "AHEAD=$(git rev-list --count "refs/heads/${recorded}..refs/heads/${branch}")"
    [ "${recreated}" -eq 0 ] || echo "RECREATED=1"
    print_submodules "${existing}" "${branch}"
    return 0
  fi

  if [ -z "${base}" ]; then
    base="$(current_branch)"
    [ -n "${base}" ] || blocked "HEAD is detached; pass --base <branch> or switch to the base branch first."
  fi
  case "${base}" in spec/*) blocked "base '${base}' is itself a change branch; start from the real base branch (or pass --base)." ;; esac
  protected_base "${base}" \
    && blocked "'${base}' is listed in worktree.protect of .yueban/config: changes must not land on it directly. Switch to (or pass --base) your own working branch."
  sha="$(rev "${base}")" || blocked "base branch '${base}' does not exist locally."
  git cat-file -e "${sha}:openspec/changes/${change}/proposal.md" 2>/dev/null \
    || blocked "'${base}' has no committed openspec/changes/${change}/proposal.md. Commit the change's spec on '${base}' first — a new worktree only sees committed files."
  [ ! -e "${path}" ] || blocked "${path} already exists but is not a worktree of ${branch}."
  leftover="$(leftover_submodule_branch "${branch}")"
  [ -z "${leftover}" ] \
    || blocked "submodule ${leftover} already has a branch ${branch} (left over from an earlier run?); a new run would pick up its commits. Check it, then delete it (git -C '${MAIN_WT}/${leftover}' branch -D ${branch}) or ask the user."

  # Branch + recorded base first, then the worktree; roll both back if anything fails, so a failed start
  # leaves nothing behind.
  git branch -q --no-track "${branch}" "${sha}" || blocked "could not create ${branch} (see above)."
  if ! config_set "branch.${branch}.yuebanSpecBase" "${base}" || ! git worktree add -q "${path}" "${branch}"; then
    git worktree prune 2>/dev/null
    git branch -q -D "${branch}" 2>/dev/null
    git config --unset "branch.${branch}.yuebanSpecBase" 2>/dev/null
    blocked "could not create the worktree (see above); nothing was left behind."
  fi
  if ! prepare_worktree "${path}" "${branch}" "${base}" 1; then
    run_hook teardown "${path}" "${branch}" "${base}" \
      || echo "WARNING: the teardown hook failed too; whatever the setup hook created outside ${path} may be left over." >&2
    git worktree remove --force "${path}" 2>/dev/null || { rm -rf "${path}"; git worktree prune 2>/dev/null; }
    drop_submodule_branches "${branch}"
    git branch -q -D "${branch}" 2>/dev/null
    git config --unset "branch.${branch}.yuebanSpecBase" 2>/dev/null
    blocked "preparing the new worktree failed (see above); the worktree and ${branch} were removed again."
  fi
  echo "WORKTREE=${path}"; echo "BRANCH=${branch}"; echo "BASE=${base}"; echo "STATE=new"; echo "AHEAD=0"
  print_submodules "${path}" "${branch}"
}


# --- integrate --------------------------------------------------------------

ff_merge() { # ff_merge <worktree> <commit>: retries briefly when another git process holds index.lock
  local i err
  for i in 1 2 3 4 5; do
    err="$(git -C "$1" merge -q --ff-only "$2" 2>&1)" && return 0
    case "${err}" in *index.lock*) sleep 1 ;; *) echo "${err}" >&2; return 1 ;; esac
  done
  echo "${err}" >&2; return 1
}

# prepare_landing <branch> <base> <old> <head>: checks, in the repository of the current directory, that <base> can
# be fast-forwarded from <old> to <head> without touching anyone's work. Prints the worktree that has <base> checked
# out (nothing when none has). Moves nothing.
prepare_landing() {
  local branch="$1" base="$2" old="$3" head="$4" busy base_wt f clash=""
  busy="$(branch_busy_worktree "${base}")"
  [ -z "${busy}" ] || blocked "${base} is being rebased or bisected in ${busy}; finish or abort that first."
  # Every commit to land must be this change's own: one also reachable from another local branch means the
  # branch was rebased onto something other than its base.
  if [ "$(git rev-list --count "${old}..${head}")" != "$( { echo "${head}"; echo "^${old}"
         git for-each-ref --format='%(refname)' refs/heads/ | grep -vxF "refs/heads/${branch}" | sed 's/^/^/'
       } | git rev-list --count --stdin)" ]; then
    blocked "${branch} in $(pwd -P) carries commits that also belong to other local branches (rebased onto something other than ${base}, or a submodule commit taken from another branch?): $(git log --oneline "${old}..${head}" | tr '\n' ';')"
  fi
  base_wt="$(branch_worktree "${base}")"
  [ "$(git worktree list --porcelain | grep -cxF "branch refs/heads/${base}")" -le 1 ] \
    || blocked "${base} is checked out in more than one worktree of $(pwd -P) (git worktree add -f?); a fast-forward would leave the others inconsistent. Switch all but one to another branch first."
  if [ -n "${base_wt}" ]; then
    is_dirty_tracked "${base_wt}" \
      && blocked "the base worktree ${base_wt} (on ${base}) has uncommitted tracked changes; a fast-forward there could clash with them. Commit or stash them, then integrate again."
    [ -z "$(git -C "${base_wt}" ls-files -u)" ] \
      || blocked "the base worktree ${base_wt} has unresolved merge conflicts; resolve them first."
    # git silently overwrites ignored files (e.g. a local .env) when a fast-forward adds a file at that path.
    while IFS= read -r -d '' f; do
      { [ -e "${base_wt}/${f}" ] || [ -L "${base_wt}/${f}" ]; } && clash="${clash} ${f}"
    done < <(git diff -z --name-only --no-renames --diff-filter=A "${old}" "${head}")
    [ -z "${clash}" ] || blocked "landing ${branch} would overwrite local (ignored/untracked) files in ${base_wt}:${clash}. Move them away or ask the user."
  fi
  printf '%s' "${base_wt}"
}

# land <repo> <base_wt> <base> <old> <head> <branch>: fast-forwards <base> from <old> to <head>.
land() {
  if [ -n "$2" ]; then
    ff_merge "$2" "$5"
  else
    git -C "$1" update-ref -m "yueban-spec: integrate $6" "refs/heads/$3" "$5" "$4"
  fi
}

# unland <repo> <base_wt> <base> <old> <head>: moves <base> back from <head> to <old>.
unland() {
  if [ -n "$2" ]; then
    [ "$(git -C "$1" rev-parse -q --verify "refs/heads/$3")" = "$5" ] || { echo "$3 moved on in $1 meanwhile" >&2; return 1; }
    git -C "$2" reset -q --keep "$4"
  else
    git -C "$1" update-ref -m "yueban-spec: undo integrate" "refs/heads/$3" "$4" "$5"
  fi
}

cmd_integrate() {
  [ $# -eq 0 ] || die "Usage: wt.sh integrate (no arguments; run inside the change worktree)"
  local branch base change top base_wt old head meta p mode_a mode_b status_letter i mb recorded
  branch="$(current_branch)"
  if [ -z "${branch}" ] && { [ -d "$(git rev-parse --git-dir)/rebase-merge" ] || [ -d "$(git rev-parse --git-dir)/rebase-apply" ]; }; then
    blocked "a rebase is still in progress here; resolve it ('git rebase --continue' or '--abort') first."
  fi
  case "${branch}" in spec/*) ;; *) blocked "not on a spec/<change> branch (on '${branch:-detached HEAD}'). Run inside the change worktree." ;; esac
  change="${branch#spec/}"
  base="$(base_of "${branch}")"
  [ -n "${base}" ] || blocked "no recorded base for ${branch} (git config branch.${branch}.yuebanSpecBase)."
  rev "${base}" >/dev/null || blocked "base branch '${base}' no longer exists."
  top="$(git rev-parse --show-toplevel)"
  head="$(git rev-parse HEAD)"
  merging_in "${top}" && blocked "a merge is still in progress here; resolve the conflicts and 'git commit' (or 'git merge --abort') first."

  # Submodules on the change branch must have everything committed and recorded before anything can land.
  local on_branch=()
  while IFS= read -r p; do [ -n "${p}" ] && on_branch+=("${p}"); done < <(branch_submodules "${top}" "${branch}")
  for p in ${on_branch[@]+"${on_branch[@]}"}; do
    merging_in "${top}/${p}" && blocked "a merge is still in progress in submodule ${p}; resolve the conflicts and 'git commit' there (or 'git merge --abort') first."
    is_dirty_tracked "${top}/${p}" && blocked "submodule ${p} has uncommitted changes; commit them on ${branch} there first."
    recorded="$(git rev-parse -q --verify "HEAD:${p}")" \
      || blocked "${branch} records no commit for submodule ${p} (removed?); ask the user how to proceed."
    git -C "${top}/${p}" cat-file -e "${recorded}^{commit}" 2>/dev/null \
      || blocked "submodule ${p} does not have the commit ${branch} records for it (${recorded:0:12}); fetch it there first."
    if [ "$(git -C "${top}/${p}" rev-parse HEAD)" != "${recorded}" ]; then
      git diff --cached --quiet -- "${p}" \
        || blocked "a pointer for submodule ${p} is staged but not committed; commit or unstage it first."
      # Behind (another change's submodule commits came in with a rebase or merge of the parent): catch up. Never
      # record the older commit, that would undo the other change in the parent.
      if git -C "${top}/${p}" merge-base --is-ancestor HEAD "${recorded}" 2>/dev/null; then
        git -C "${top}/${p}" merge -q --ff-only "${recorded}" \
          || blocked "submodule ${p} is behind the commit ${branch} records for it, and fast-forwarding it failed (see above)."
        echo "NOTE: fast-forwarded submodule ${p} to the commit ${branch} records for it (${recorded:0:12})." >&2
      elif git -C "${top}/${p}" merge-base --is-ancestor "${recorded}" HEAD 2>/dev/null; then
        blocked "submodule ${p} has commits ${branch} does not record yet; record them: git add '${p}' && git commit."
      else
        blocked "submodule ${p} and the commit ${branch} records for it (${recorded:0:12}) have diverged (both have their own commits); merge it there (git -C '${p}' merge --no-edit ${recorded}), then git add '${p}' && git commit."
      fi
    fi
  done
  is_dirty "${top}" && blocked "the change worktree has uncommitted changes; commit or clean them first."
  [ ! -d "${top}/openspec/changes/${change}" ] \
    || blocked "openspec/changes/${change} still exists — the change is not archived yet."
  if is_ancestor "${head}" "refs/heads/${base}"; then
    echo "ALREADY_INTEGRATED: ${base} already contains ${branch}; nothing to land. Go on with cleanup."
    echo "BASE=${base}"; echo "HEAD=${head}"
    return 0
  fi

  # The submodule pointers this branch changes (plumbing with --ignore-submodules=none and -z, so neither
  # submodule.<name>.ignore, diff.ignoreSubmodules nor quoted paths can hide one): each must be a submodule on the
  # branch that shares its repository with the main worktree's submodule, so its commits can land on the base there.
  local subs=() sub_repo nested
  mb="$(git merge-base "refs/heads/${base}" HEAD)" || blocked "${branch} and ${base} have no common history."
  while IFS= read -r -d '' meta && IFS= read -r -d '' p; do
    mode_a="$(printf '%s' "${meta}" | awk '{print substr($1,2)}')"
    mode_b="$(printf '%s' "${meta}" | awk '{print $2}')"
    status_letter="$(printf '%s' "${meta}" | awk '{print substr($5,1,1)}')"
    [ "${mode_a}" = 160000 ] || [ "${mode_b}" = 160000 ] || continue
    [ "${mode_a}" = 160000 ] && [ "${mode_b}" = 160000 ] && [ "${status_letter}" = M ] \
      || blocked "${branch} adds, removes or replaces the submodule ${p}; this flow cannot land that. Ask the user how to proceed."
    in_list "${p}" ${on_branch[@]+"${on_branch[@]}"} \
      || blocked "${branch} changes submodule pointers (${p}), but ${p} is not on ${branch} in this worktree (detached HEAD?). Submodule commits can only land when the submodule is on the change branch, e.g. set up by a .yueban/config setup hook. Ask the user how to proceed."
    sub_repo="$(common_dir_of "${top}/${p}")"
    [ -e "${MAIN_WT}/${p}/.git" ] && [ -n "${sub_repo}" ] && [ "${sub_repo}" = "$(common_dir_of "${MAIN_WT}/${p}")" ] \
      || blocked "submodule ${p} in this worktree is not a worktree of the repository at ${MAIN_WT}/${p}, so its commits would not reach ${base} there. Ask the user how to proceed."
    git -C "${top}/${p}" rev-parse -q --verify "refs/heads/${base}^{commit}" >/dev/null \
      || blocked "submodule ${p} has no branch ${base} to land on; create it there (on the commit ${base} records for ${p}) or ask the user."
    # Nested submodules live in the change worktree's own git dirs and would be lost with it.
    nested="$(git -C "${top}/${p}" diff-tree -r --raw --ignore-submodules=none "$(git rev-parse "${mb}:${p}")" "$(git rev-parse "HEAD:${p}")")" \
      || blocked "cannot compare submodule ${p} with what ${base} records for it (missing commits? fetch them there first)."
    [ -z "$(printf '%s\n' "${nested}" | awk '$1 ~ /160000/ || $2 ~ /160000/')" ] \
      || blocked "${branch} changes a nested submodule inside ${p}; this flow cannot land that. Ask the user how to proceed."
    subs+=("${p}")
  done < <(git diff-tree -r -z --raw --no-renames --ignore-submodules=none "${mb}" HEAD)

  # Global, not local: the EXIT trap runs after this function has returned. Set before taking the lock (it only
  # removes a lock carrying this token), so there is no window in which we hold the lock without the trap.
  INTEGRATE_TOKEN="$(new_token)"
  trap 'lock_release_if_mine "${INTEGRATE_TOKEN}"' EXIT
  # Trapped signals wait for the running git command to finish before exiting (and releasing the lock), so a
  # TERM can't free the lock while a fast-forward is still writing the base worktree.
  trap 'exit 143' TERM INT HUP
  lock_acquire "${LOCK_WAIT_DEFAULT}" "${INTEGRATE_TOKEN}" "integrate ${branch}" "$$"

  old="$(rev "${base}")" || blocked "base branch '${base}' disappeared."
  local sub_old=() sub_head=() sync=() sha
  for p in ${subs[@]+"${subs[@]}"}; do
    sha="$(git -C "${top}/${p}" rev-parse -q --verify "refs/heads/${base}^{commit}")" \
      || blocked "submodule ${p}'s branch ${base} disappeared."
    sub_old+=("${sha}")
    sub_head+=("$(git rev-parse "HEAD:${p}")")
  done
  for i in ${subs[@]+"${!subs[@]}"}; do
    git -C "${top}/${subs[i]}" merge-base --is-ancestor "${sub_old[i]}" "${sub_head[i]}" 2>/dev/null || sync+=("${subs[i]}")
  done
  is_ancestor "${old}" "${head}" || sync+=(".")
  if [ ${#sync[@]} -gt 0 ]; then
    if [ ${#subs[@]} -eq 0 ]; then
      echo "NEEDS_REBASE: ${base} has commits this branch doesn't. Run 'git rebase refs/heads/${base}', resolve conflicts; then bring the submodules up to the commits the rebased branch records ('git submodule update --init --recursive' without a setup hook; for each SUBMODULE_ON_BRANCH path: git -C <path> merge --ff-only \$(git rev-parse HEAD:<path>)). Re-test, then integrate again." >&2
      echo "SYNC=rebase"
    else
      echo "NEEDS_MERGE: ${base} moved on in: $(printf "'%s' " "${sync[@]}")('.' is the parent). This branch carries submodule commits, so catch up by merging, not rebasing (a rebase would rewrite submodule commits the parent's history points to). In each listed submodule first, then in the parent ('.'): git merge --no-edit refs/heads/${base}. A conflict on a submodule path in the parent: git add <path> (takes the submodule's current commit). Record the submodule pointers (git add <paths> && git commit) if the merge left them modified, re-test, then integrate again." >&2
      echo "SYNC=merge"
    fi
    for p in "${sync[@]}"; do echo "SYNC_REPO=${p}"; done
    echo "INCOMING_PATHS:"
    for i in ${subs[@]+"${!subs[@]}"}; do
      in_list "${subs[i]}" "${sync[@]}" \
        && git -C "${top}/${subs[i]}" diff --name-only "${sub_head[i]}...${sub_old[i]}" | sed "s#^#  ${subs[i]}/#"
    done
    is_ancestor "${old}" "${head}" || git diff --name-only "${head}...${old}" | sed 's/^/  /'
    exit 3
  fi

  # Check every repository before moving any base, so a refusal never leaves the landing half done. A submodule's
  # base must be checked out exactly where the parent's is (in that checkout's submodule), or nowhere when the
  # parent's is not: anything else leaves a checkout whose parent records another submodule commit than it has.
  local sub_wt=() w want
  base_wt="$(prepare_landing "${branch}" "${base}" "${old}" "${head}")" || exit $?
  for i in ${subs[@]+"${!subs[@]}"}; do
    w="$(cd "${top}/${subs[i]}" && set_ctx && prepare_landing "${branch}" "${base}" "${sub_old[i]}" "${sub_head[i]}")" || exit $?
    want=""
    if [ -n "${base_wt}" ] && [ -e "${base_wt}/${subs[i]}/.git" ]; then
      [ "$(common_dir_of "${base_wt}/${subs[i]}")" = "$(common_dir_of "${top}/${subs[i]}")" ] \
        || blocked "${base_wt}/${subs[i]} (in the checkout of ${base}) is a separate repository from this change's ${subs[i]}; landing would leave it behind its parent. Ask the user how to proceed."
      want="$(physical "${base_wt}/${subs[i]}")"
    fi
    if [ "$(physical "${w:-/nonexistent}")" != "${want}" ]; then
      [ -z "${want}" ] \
        || blocked "${base_wt} has ${base} checked out, but its submodule ${subs[i]} is not on ${base}${w:+ (${base} is checked out at ${w})}; landing would leave the two out of step. Switch it: git -C '${base_wt}/${subs[i]}' switch ${base} — or ask the user."
      blocked "submodule ${subs[i]}'s ${base} is checked out at ${w}, but the parent's ${base} is not checked out with that submodule set up; landing would leave that checkout's parent out of step. Switch it to another branch or ask the user."
    fi
    sub_wt+=("${w}")
  done

  # Submodules first, then the parent; if a later move fails, the earlier ones are undone.
  local moved=() j failed=""
  for i in ${subs[@]+"${!subs[@]}"}; do
    [ "${sub_old[i]}" != "${sub_head[i]}" ] || continue
    if land "${top}/${subs[i]}" "${sub_wt[i]}" "${base}" "${sub_old[i]}" "${sub_head[i]}" "${branch}"; then
      moved+=("${i}")
    else
      failed="submodule ${subs[i]}"; break
    fi
  done
  if [ -z "${failed}" ] && ! land "${top}" "${base_wt}" "${base}" "${old}" "${head}" "${branch}"; then failed="the parent"; fi
  if [ -n "${failed}" ]; then
    local undo_failed=""
    for ((j=${#moved[@]}-1; j>=0; j--)); do
      i="${moved[j]}"
      unland "${top}/${subs[i]}" "${sub_wt[i]}" "${base}" "${sub_old[i]}" "${sub_head[i]}" \
        || undo_failed="${undo_failed} ${subs[i]} (${base} should go back to ${sub_old[i]})"
    done
    [ -z "${undo_failed}" ] \
      || blocked "landing failed in ${failed} (see above), and moving ${base} back failed in:${undo_failed}. Fix those by hand."
    blocked "landing failed in ${failed} (see above); every ${base} is back where it was."
  fi

  for i in ${subs[@]+"${!subs[@]}"}; do
    echo "INTEGRATED_SUBMODULE: ${subs[i]} ${base} ${sub_old[i]:0:12} -> ${sub_head[i]:0:12}"
  done
  [ -z "${base_wt}" ] || echo "BASE_WORKTREE=${base_wt}"
  echo "INTEGRATED: ${base} ${old:0:12} -> ${head:0:12} ($(git rev-list --count "${old}..${head}") commit(s) from ${branch})"
  echo "BASE=${base}"; echo "HEAD=${head}"
}

# --- cleanup ----------------------------------------------------------------

cmd_cleanup() {
  [ $# -eq 1 ] || die "Usage: wt.sh cleanup <change>"
  check_change_name "$1"
  local change="$1" branch="spec/$1" base wt wt_phys here p repo tip recorded dirt sub_branches=() not_landed="" failed=""
  branch_exists "${branch}" || blocked "branch ${branch} does not exist."
  base="$(base_of "${branch}")"
  [ -n "${base}" ] || blocked "no recorded base for ${branch}."
  rev "${base}" >/dev/null || blocked "${branch}'s base '${base}' no longer exists."
  is_ancestor "refs/heads/${branch}" "refs/heads/${base}" \
    || blocked "${branch} is not fully on ${base} yet; run integrate first (cleanup would lose commits)."
  [ -z "$(branch_rebasing_worktree "${branch}")" ] || blocked "${branch} is in the middle of a rebase; finish or abort it first."
  # The change's branches in the main worktree's submodule repositories go too, but only when every commit on
  # them is reachable from some other ref there (the base, usually), so deleting them loses nothing.
  while IFS= read -r p; do
    [ -n "${p}" ] && [ -e "${MAIN_WT}/${p}/.git" ] || continue
    repo="${MAIN_WT}/${p}"
    tip="$(git -C "${repo}" rev-parse -q --verify "refs/heads/${branch}^{commit}")" || continue
    recorded="$(git rev-parse -q --verify "refs/heads/${base}:${p}" 2>/dev/null)"
    if git -C "${repo}" for-each-ref --contains "${tip}" --format='%(refname)' 2>/dev/null | grep -qvxF "refs/heads/${branch}" \
       || { [ -n "${recorded}" ] && git -C "${repo}" merge-base --is-ancestor "${tip}" "${recorded}" 2>/dev/null; }; then
      sub_branches+=("${p}")
    else
      not_landed="${not_landed} ${p}"
    fi
  done < <(submodule_paths "${MAIN_WT}")
  [ -z "${not_landed}" ] \
    || blocked "${branch} in submodule(s)${not_landed} has commits that are not on ${base} there; land them (integrate) or ask the user. Nothing was removed."
  wt="$(branch_worktree "${branch}")"
  if [ -n "${wt}" ]; then
    wt_phys="$(physical "${wt}")"; here="$(pwd -P)"
    [ -n "${wt_phys}" ] || blocked "cannot access ${wt}."
    case "${here}/" in "${wt_phys}/"*) blocked "you are inside ${wt}; cd to ${MAIN_WT} and run cleanup from there." ;; esac
    if [ -n "$(hook_cmd "${wt}" teardown 2>/dev/null)" ]; then dirt="$(dirty_beyond_removed_submodules "${wt}")"
    else dirt="$(git -C "${wt}" status --porcelain --ignore-submodules=untracked 2>/dev/null)"; fi
    [ -z "${dirt}" ] \
      || blocked "${wt} has uncommitted or untracked files (or submodules off their recorded commit); check them, then remove them or the worktree yourself."
    run_hook teardown "${wt}" "${branch}" "${base}" \
      || blocked "the teardown hook failed in ${wt} (see above); the worktree and ${branch} are kept. Fix the cause and run cleanup again."
    # Submodules make plain 'worktree remove' refuse. The checks above guarantee every submodule sits on the
    # commit the (already integrated) branch records, so --force only drops build output.
    if [ -f "${wt}/.gitmodules" ]; then
      git worktree remove --force "${wt}" || blocked "git worktree remove failed (see above)."
    else
      git worktree remove "${wt}" || blocked "git worktree remove failed (see above)."
    fi
  fi
  git branch -q -D "${branch}" \
    || blocked "removed ${wt:-no worktree} but could not delete ${branch} (see above); delete it by hand — it is fully on ${base}."
  git config --unset "branch.${branch}.yuebanSpecBase" 2>/dev/null || true
  for p in ${sub_branches[@]+"${sub_branches[@]}"}; do
    git -C "${MAIN_WT}/${p}" worktree prune 2>/dev/null
    git -C "${MAIN_WT}/${p}" branch -q -D "${branch}" || failed="${failed} ${p}"
  done
  [ -z "${failed}" ] \
    || blocked "removed ${wt:-no worktree} and ${branch}, but could not delete ${branch} in submodule(s)${failed} (see above; still checked out somewhere?). It is fully landed there; delete it by hand."
  echo "CLEANED: ${branch}${wt:+ and ${wt}}${sub_branches[*]+ (and ${branch} in: ${sub_branches[*]})}"
}


# --- landed -----------------------------------------------------------------

cmd_landed() {
  local change="" base=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] && [ -n "$2" ] || die "--base needs a branch name"; base="$2"; shift 2 ;;
      -*) die "Unknown option: $1" ;;
      *) [ -z "${change}" ] || die "Only one change name."; change="$1"; shift ;;
    esac
  done
  [ -n "${change}" ] || die "Usage: wt.sh landed <change> [--base <branch>]"
  check_change_name "${change}"
  [ -n "${base}" ] || base="$(base_of "spec/${change}")"
  [ -n "${base}" ] || base="$(current_branch)"
  [ -n "${base}" ] || die "Pass --base <branch> (HEAD is detached)."
  rev "${base}" >/dev/null || blocked "base branch '${base}' does not exist."
  echo "LANDED=$(landed_state "${change}" "${base}")"
  echo "BASE=${base}"
}

# --- lock / unlock / status -------------------------------------------------

cmd_lock() {
  local wait="${LOCK_WAIT_DEFAULT}" token
  if [ $# -gt 0 ]; then
    [ "$1" = "--wait" ] && [ $# -eq 2 ] || die "Usage: wt.sh lock [--wait <seconds>]"
    is_seconds "$2" || die "--wait needs a number of seconds (at most 6 digits)"
    wait="$2"
  fi
  token="$(new_token)"
  lock_acquire "${wait}" "${token}" "lock (manual, $(current_branch))"
  echo "LOCK_TOKEN=${token}"
  echo "LOCKED: ${LOCK_DIR} — run 'wt.sh unlock ${token}' as soon as you are done."
}

cmd_unlock() {
  [ $# -eq 1 ] && [ -n "$1" ] || die "Usage: wt.sh unlock <token printed by lock>"
  [ -d "${LOCK_DIR}" ] || { echo "not locked"; return 0; }
  [ "$(lock_token)" = "$1" ] || blocked "the lock is held by someone else ($(lock_describe)); not touching it."
  rm -rf "${LOCK_DIR}"; echo "UNLOCKED"
}

cmd_status() {
  local found=0 branch base wt
  git worktree prune 2>/dev/null
  while IFS= read -r branch; do
    found=1; base="$(base_of "${branch}")"; wt="$(branch_worktree "${branch}")"
    if [ -n "${base}" ] && rev "${base}" >/dev/null; then
      printf '%s\t%s\tbase=%s\tstate=%s\tahead=%s\tbehind=%s\tdirty=%s\n' "${branch}" "${wt:-(no worktree)}" "${base}" \
        "$(change_state "${branch}" "${wt}")" \
        "$(git rev-list --count "refs/heads/${base}..refs/heads/${branch}")" \
        "$(git rev-list --count "refs/heads/${branch}..refs/heads/${base}")" \
        "$( [ -z "${wt}" ] && echo - || { is_dirty "${wt}" && echo yes || echo no; } )"
    else
      printf '%s\t%s\tbase=?\n' "${branch}" "${wt:-(no worktree)}"
    fi
  done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/spec/')
  [ "${found}" -eq 1 ] || echo "no spec/* branches"
  [ -d "${LOCK_DIR}" ] && echo "integration lock held: $(lock_describe) (dir: ${LOCK_DIR})"
  return 0
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "${cmd}" in
  start) cmd_start "$@" ;;
  integrate) cmd_integrate "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  landed) cmd_landed "$@" ;;
  lock) cmd_lock "$@" ;;
  unlock) cmd_unlock "$@" ;;
  status) [ $# -eq 0 ] || die "Usage: wt.sh status"; cmd_status ;;
  *) die "Unknown command: ${cmd} (start / integrate / cleanup / landed / lock / unlock / status)" ;;
esac
