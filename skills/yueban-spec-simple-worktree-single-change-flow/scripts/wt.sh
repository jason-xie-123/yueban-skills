#!/usr/bin/env bash
# wt.sh — git worktree plumbing for yueban-spec-simple-worktree-single-change-flow (and the roadmap flow that
# runs several of them in parallel): give one OpenSpec change its own worktree + branch off a base branch, then
# land the finished branch back onto the base as a fast-forward, serialized by a repo-wide lock so parallel
# changes never race on the base branch. See ../SKILL.md for the workflow this script serves.
#
# Usage:
#   wt.sh start     <change> [--base <branch>]   Create (or reuse) <main worktree>/.worktrees/<change> on branch
#                                                spec/<change>. Base defaults to the current branch. Prints STATE=
#                                                (new / in_progress / archived / integrated / rebasing).
#   wt.sh integrate                              Run inside the change worktree: fast-forward the base branch to
#                                                this branch. Exits 3 when the branch must be rebased first.
#   wt.sh cleanup   <change>                     Run outside the change worktree, after integrate: remove the
#                                                worktree and delete spec/<change>.
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
# Exit codes:
#   0 = done (integrate also exits 0 with ALREADY_INTEGRATED when there is nothing left to land)
#   1 = usage error
#   2 = BLOCKED: report the message to the user; nothing was changed unless the message says otherwise
#   3 = NEEDS_REBASE (integrate only): base moved on; rebase onto it, re-test, then integrate again

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
COMMON_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
LOCK_DIR="${COMMON_DIR}/yueban-spec-integrate.lock"
# The main worktree is always listed first; .worktrees/ lives there even when called from a linked worktree.
MAIN_WT="$(git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')"

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

lock_acquire() { # lock_acquire <wait-seconds> <token> <label>
  local waited=0
  while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
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
  info="$(head -1 "${LOCK_DIR}/owner" 2>/dev/null)"
  pid="$(printf '%s' "${info}" | sed -n 's/.* pid=\([0-9][0-9]*\) .*/\1/p')"
  if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then info="${info}; holder process ${pid} is gone, so the lock is probably stale"; fi
  printf '%s' "${info:-no owner info}"
}
lock_token() { sed -n 's/^token=\([^ ]*\).*/\1/p' "${LOCK_DIR}/owner" 2>/dev/null; }
lock_release_if_mine() { [ -n "$1" ] && [ "$(lock_token)" = "$1" ] && rm -rf "${LOCK_DIR}"; return 0; }
new_token() { printf '%s-%s-%s' "$(date +%s)" "$$" "${RANDOM}${RANDOM}"; }

# --- start ------------------------------------------------------------------

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

  local branch="spec/${change}" path="${MAIN_WT}/.worktrees/${change}" existing recorded recreated=0 sha
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
      [ -f "${path}/.gitmodules" ] && git -C "${path}" submodule update --init --recursive -q
    fi
    echo "WORKTREE=${existing}"; echo "BRANCH=${branch}"; echo "BASE=${recorded}"
    echo "STATE=$(change_state "${branch}" "${existing}")"
    echo "AHEAD=$(git rev-list --count "refs/heads/${recorded}..refs/heads/${branch}")"
    [ "${recreated}" -eq 0 ] || echo "RECREATED=1"
    return 0
  fi

  if [ -z "${base}" ]; then
    base="$(current_branch)"
    [ -n "${base}" ] || blocked "HEAD is detached; pass --base <branch> or switch to the base branch first."
  fi
  case "${base}" in spec/*) blocked "base '${base}' is itself a change branch; start from the real base branch (or pass --base)." ;; esac
  sha="$(rev "${base}")" || blocked "base branch '${base}' does not exist locally."
  git cat-file -e "${sha}:openspec/changes/${change}/proposal.md" 2>/dev/null \
    || blocked "'${base}' has no committed openspec/changes/${change}/proposal.md. Commit the change's spec on '${base}' first — a new worktree only sees committed files."
  [ ! -e "${path}" ] || blocked "${path} already exists but is not a worktree of ${branch}."

  # Branch + recorded base first, then the worktree; roll both back if anything fails, so a failed start
  # leaves nothing behind.
  git branch -q --no-track "${branch}" "${sha}" || blocked "could not create ${branch} (see above)."
  if ! config_set "branch.${branch}.yuebanSpecBase" "${base}" || ! git worktree add -q "${path}" "${branch}"; then
    git worktree prune 2>/dev/null
    git branch -q -D "${branch}" 2>/dev/null
    git config --unset "branch.${branch}.yuebanSpecBase" 2>/dev/null
    blocked "could not create the worktree (see above); nothing was left behind."
  fi
  if [ -f "${path}/.gitmodules" ]; then
    git -C "${path}" submodule update --init --recursive -q \
      || echo "WARNING: submodule init failed in ${path}; build/test there may break." >&2
    echo "NOTE: submodules in the new worktree are on detached HEADs; changes inside them are not supported by this flow." >&2
  fi
  echo "WORKTREE=${path}"; echo "BRANCH=${branch}"; echo "BASE=${base}"; echo "STATE=new"; echo "AHEAD=0"
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

cmd_integrate() {
  [ $# -eq 0 ] || die "Usage: wt.sh integrate (no arguments; run inside the change worktree)"
  local branch base change top base_wt busy old head
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

  is_dirty "${top}" && blocked "the change worktree has uncommitted changes; commit or clean them first."
  [ ! -d "${top}/openspec/changes/${change}" ] \
    || blocked "openspec/changes/${change} still exists — the change is not archived yet."
  if is_ancestor "${head}" "refs/heads/${base}"; then
    echo "ALREADY_INTEGRATED: ${base} already contains ${branch}; nothing to land. Go on with cleanup."
    echo "BASE=${base}"; echo "HEAD=${head}"
    return 0
  fi
  if [ -n "$(git diff --raw "refs/heads/${base}...HEAD" | awk '$1 ~ /160000/ || $2 ~ /160000/')" ]; then
    blocked "${branch} changes submodule pointers; this flow cannot land submodule changes. Ask the user how to proceed."
  fi

  # Global, not local: the EXIT trap runs after this function has returned. Set before taking the lock (it only
  # removes a lock carrying this token), so there is no window in which we hold the lock without the trap.
  INTEGRATE_TOKEN="$(new_token)"
  trap 'lock_release_if_mine "${INTEGRATE_TOKEN}"' EXIT
  # Trapped signals wait for the running git command to finish before exiting (and releasing the lock), so a
  # TERM can't free the lock while a fast-forward is still writing the base worktree.
  trap 'exit 143' TERM INT HUP
  lock_acquire "${LOCK_WAIT_DEFAULT}" "${INTEGRATE_TOKEN}" "integrate ${branch}" "$$"

  old="$(rev "${base}")" || blocked "base branch '${base}' disappeared."
  if ! is_ancestor "${old}" "${head}"; then
    echo "NEEDS_REBASE: ${base} has commits this branch doesn't. Run 'git rebase refs/heads/${base}' (plus 'git submodule update --init --recursive' if the repo has submodules), resolve conflicts, re-test, then integrate again." >&2
    echo "INCOMING_PATHS:"; git diff --name-only "${head}...${old}" | sed 's/^/  /'
    exit 3
  fi
  busy="$(branch_busy_worktree "${base}")"
  [ -z "${busy}" ] || blocked "${base} is being rebased or bisected in ${busy}; finish or abort that first."
  # Every commit to land must be this change's own: one also reachable from another local branch means the
  # branch was rebased onto something other than its base.
  if [ "$(git rev-list --count "${old}..${head}")" != "$( { echo "${head}"; echo "^${old}"
         git for-each-ref --format='%(refname)' refs/heads/ | grep -vxF "refs/heads/${branch}" | sed 's/^/^/'
       } | git rev-list --count --stdin)" ]; then
    blocked "${branch} carries commits that also belong to other local branches (rebased onto something other than ${base}?): $(git log --oneline "${old}..${head}" | tr '\n' ';')"
  fi

  base_wt="$(branch_worktree "${base}")"
  [ "$(git worktree list --porcelain | grep -cxF "branch refs/heads/${base}")" -le 1 ] \
    || blocked "${base} is checked out in more than one worktree (git worktree add -f?); a fast-forward would leave the others inconsistent. Switch all but one to another branch first."
  if [ -n "${base_wt}" ]; then
    is_dirty_tracked "${base_wt}" \
      && blocked "the base worktree ${base_wt} (on ${base}) has uncommitted tracked changes; a fast-forward there could clash with them. Commit or stash them, then integrate again."
    [ -z "$(git -C "${base_wt}" ls-files -u)" ] \
      || blocked "the base worktree ${base_wt} has unresolved merge conflicts; resolve them first."
    # git silently overwrites ignored files (e.g. a local .env) when a fast-forward adds a file at that path.
    local f clash=""
    while IFS= read -r f; do
      { [ -e "${base_wt}/${f}" ] || [ -L "${base_wt}/${f}" ]; } && clash="${clash} ${f}"
    done < <(git diff --name-only --no-renames --diff-filter=A "${old}" "${head}")
    [ -z "${clash}" ] || blocked "landing ${branch} would overwrite local (ignored/untracked) files in ${base_wt}:${clash}. Move them away or ask the user."
    ff_merge "${base_wt}" "${head}" \
      || blocked "git merge --ff-only failed in ${base_wt} (see above); ${base} is unchanged."
    echo "BASE_WORKTREE=${base_wt}"
  else
    git update-ref -m "yueban-spec: integrate ${branch}" "refs/heads/${base}" "${head}" "${old}" \
      || blocked "could not move ${base} (it changed concurrently?)."
  fi
  echo "INTEGRATED: ${base} ${old:0:12} -> ${head:0:12} ($(git rev-list --count "${old}..${head}") commit(s) from ${branch})"
  echo "BASE=${base}"; echo "HEAD=${head}"
}

# --- cleanup ----------------------------------------------------------------

cmd_cleanup() {
  [ $# -eq 1 ] || die "Usage: wt.sh cleanup <change>"
  check_change_name "$1"
  local change="$1" branch="spec/$1" base wt wt_phys here
  branch_exists "${branch}" || blocked "branch ${branch} does not exist."
  base="$(base_of "${branch}")"
  [ -n "${base}" ] || blocked "no recorded base for ${branch}."
  rev "${base}" >/dev/null || blocked "${branch}'s base '${base}' no longer exists."
  is_ancestor "refs/heads/${branch}" "refs/heads/${base}" \
    || blocked "${branch} is not fully on ${base} yet; run integrate first (cleanup would lose commits)."
  [ -z "$(branch_rebasing_worktree "${branch}")" ] || blocked "${branch} is in the middle of a rebase; finish or abort it first."
  wt="$(branch_worktree "${branch}")"
  if [ -n "${wt}" ]; then
    wt_phys="$(physical "${wt}")"; here="$(pwd -P)"
    [ -n "${wt_phys}" ] || blocked "cannot access ${wt}."
    case "${here}/" in "${wt_phys}/"*) blocked "you are inside ${wt}; cd to ${MAIN_WT} and run cleanup from there." ;; esac
    is_dirty "${wt}" && blocked "${wt} has uncommitted or untracked files (or submodules off their recorded commit); check them, then remove them or the worktree yourself."
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
  echo "CLEANED: ${branch}${wt:+ and ${wt}}"
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
