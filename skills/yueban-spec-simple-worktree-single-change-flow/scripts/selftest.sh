#!/usr/bin/env bash
# selftest.sh — regression tests for wt.sh against throwaway repos in a temp dir (paths with spaces, one repo with a
# submodule): start/resume, integrate as a fast-forward of the base worktree, NEEDS_REBASE after a parallel change
# landed first, two integrates racing, the integration lock and its tokens, cleanup, and the edge cases found in
# review (deleted worktree dirs, a base being rebased, a tag named like the base, submodule changes, bad arguments).
# Touches nothing outside the temp dir.
# Usage: selftest.sh      Exit code: 0 = all passed, 1 = a case failed.
set -uo pipefail

WT="$(cd "$(dirname "$0")" && pwd -P)/wt.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wt-selftest.XXXXXX")"
TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export YUEBAN_WT_LOCK_WAIT=5   # keep lock waits short; nothing here should wait for real
fail=0
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@"; then echo "ok   ${label}"; else echo "FAIL ${label}"; printf '     rc=%s out: %s\n' "${rc:-}" "${out:-}" | head -5; fail=1; fi
}
contains() { printf '%s' "${out}" | grep -q -- "$1"; }
run() { out="$("$@" 2>&1)"; rc=$?; }
in_dir() { local d="$1"; shift; ( cd "$d" && "$@" ); }
lockdir() { echo "$(git rev-parse --git-common-dir)/yueban-spec-integrate.lock"; }
add_change() { # add_change <name>: a committed, pending OpenSpec change
  mkdir -p "openspec/changes/$1" && echo "# $1" > "openspec/changes/$1/proposal.md"
  git add "openspec/changes/$1" && git commit -q -m "spec: $1"
}
implement() { # implement <worktree> <name> <file>: a commit on the change branch
  ( cd "$1" && echo "$2" > "$3" && git add "$3" && git commit -q -m "feat: $2" )
}
archive() { # archive <worktree> <name>: archive + commit, as the flow would
  ( cd "$1" && mkdir -p openspec/changes/archive \
    && git mv "openspec/changes/$2" "openspec/changes/archive/2026-01-01-$2" && git commit -q -m "archive: $2" )
}
finish_change() { implement "$1" "$2" "$3" && archive "$1" "$2"; }

M="${TMP}/main repo"; mkdir -p "${M}" && cd "${M}" || exit 1
git init -q -b develop && printf '.worktrees/\n' > .gitignore && git add .gitignore && git commit -q -m init
for c in alpha beta gamma delta eps zeta eta; do add_change "${c}"; done

echo "start"
run "${WT}" start alpha
check "start creates .worktrees/alpha on spec/alpha" eval '[ "${rc}" -eq 0 ] && [ "$(git -C .worktrees/alpha branch --show-current)" = spec/alpha ]'
check "start prints WORKTREE=, BASE= and STATE=new" eval 'contains "^WORKTREE=${M}/.worktrees/alpha" && contains "^BASE=develop" && contains "^STATE=new"'
run "${WT}" start alpha
check "start again reuses the worktree with STATE=in_progress" eval '[ "${rc}" -eq 0 ] && contains "^STATE=in_progress" && contains "^AHEAD=0" && ! contains RECREATED'
run "${WT}" start alpha --base other
check "start refuses a --base that differs from the recorded one" eval '[ "${rc}" -eq 2 ] && contains "was started from"'
run "${WT}" start nope
check "start blocks a change that is not committed on the base" eval '[ "${rc}" -eq 2 ] && contains "proposal.md"'
run "${WT}" start nope --base
check "start --base without a value is a usage error, not a hang" eval '[ "${rc}" -eq 1 ] && contains "needs a branch"'
run in_dir "${M}/.worktrees/alpha" "${WT}" start beta --base develop
check "start from inside a change worktree still creates it under the main worktree" eval '[ "${rc}" -eq 0 ] && [ -d "${M}/.worktrees/beta" ] && [ ! -e "${M}/.worktrees/alpha/.worktrees" ]'
run in_dir "${M}/.worktrees/alpha" "${WT}" start gamma
check "start without --base inside a change worktree refuses spec/* as base" eval '[ "${rc}" -eq 2 ] && contains "itself a change branch"'

echo "integrate"
cd "${M}/.worktrees/alpha" || exit 1
implement "${M}/.worktrees/alpha" alpha a.txt
run "${WT}" integrate
check "integrate blocks before the change is archived" eval '[ "${rc}" -eq 2 ] && contains "not archived"'
archive "${M}/.worktrees/alpha" alpha
echo dirty > "${M}/.gitignore"
run "${WT}" integrate
check "integrate blocks when the base worktree has tracked edits" eval '[ "${rc}" -eq 2 ] && contains "uncommitted tracked changes"'
check "the lock is released after a BLOCKED inside the lock" eval '[ ! -d "$(lockdir)" ]'
git -C "${M}" checkout -q -- .gitignore
run "${WT}" integrate
check "integrate fast-forwards develop in the base worktree" eval '[ "${rc}" -eq 0 ] && [ "$(git -C "${M}" rev-parse develop)" = "$(git rev-parse HEAD)" ] && [ -f "${M}/a.txt" ]'
check "the base worktree has no leftover changes" eval '[ -z "$(git -C "${M}" status --porcelain)" ]'
check "the lock is released after a successful integrate" eval '[ ! -d "$(lockdir)" ]'
run "${WT}" integrate
check "integrating again reports ALREADY_INTEGRATED with exit 0" eval '[ "${rc}" -eq 0 ] && contains "ALREADY_INTEGRATED" && contains "^HEAD="'
run "${WT}" start alpha
check "start on an integrated change reports STATE=integrated" contains "^STATE=integrated"
run "${WT}" landed alpha
check "landed says yes for an archived change" eval '[ "${rc}" -eq 0 ] && contains "^LANDED=yes"'
run "${WT}" landed beta
check "landed says no for a change still pending on the base" contains "^LANDED=no"
run "${WT}" landed alph
check "landed says unknown for a misspelled change (no suffix match on add-alpha style names)" contains "^LANDED=unknown"
run "${WT}" landed lpha
check "landed does not match a suffix of another change's archive dir" contains "^LANDED=unknown"

cd "${M}/.worktrees/beta" || exit 1
finish_change "${M}/.worktrees/beta" beta b.txt
run "${WT}" integrate
check "integrate exits 3 when develop moved on, listing the incoming paths" eval '[ "${rc}" -eq 3 ] && contains "NEEDS_REBASE" && contains "  a.txt"'
check "the lock is released after NEEDS_REBASE" eval '[ ! -d "$(lockdir)" ]'
git rebase -q develop
run "${WT}" integrate
check "integrate succeeds after rebasing" eval '[ "${rc}" -eq 0 ] && [ -f "${M}/a.txt" ] && [ -f "${M}/b.txt" ]'

echo "two integrates racing"
cd "${M}" || exit 1
"${WT}" start gamma >/dev/null 2>&1; "${WT}" start delta >/dev/null 2>&1
finish_change "${M}/.worktrees/gamma" gamma c.txt; finish_change "${M}/.worktrees/delta" delta d.txt
( cd "${M}/.worktrees/gamma" && "${WT}" integrate >/dev/null 2>&1; echo $? > "${TMP}/rc.gamma" ) &
( cd "${M}/.worktrees/delta" && "${WT}" integrate >/dev/null 2>&1; echo $? > "${TMP}/rc.delta" ) &
wait
check "exactly one racing integrate lands, the other needs a rebase" eval '[ "$(cat "${TMP}"/rc.* | sort | tr "\n" " ")" = "0 3 " ]'
check "the lock is free after the race" eval '[ ! -d "$(lockdir)" ]'
for c in gamma delta; do ( cd "${M}/.worktrees/${c}" && git rebase -q develop 2>/dev/null; "${WT}" integrate >/dev/null 2>&1 ); done
check "after rebasing, both racing changes are on develop" eval '[ -f c.txt ] && [ -f d.txt ]'

echo "lock tokens"
run "${WT}" lock --wait abc
check "lock --wait with a non-number is a usage error, not a hang" eval '[ "${rc}" -eq 1 ]'
run "${WT}" lock
token="$(printf '%s\n' "${out}" | sed -n 's/^LOCK_TOKEN=//p')"
check "lock prints a token" eval '[ "${rc}" -eq 0 ] && [ -n "${token}" ]'
run "${WT}" status
check "status shows the held lock" contains "integration lock held"
run "${WT}" lock --wait 0
check "a second lock is BLOCKED while the lock is held" eval '[ "${rc}" -eq 2 ] && contains "still held"'
run "${WT}" unlock wrong-token
check "unlock with someone else's token leaves the lock alone" eval '[ "${rc}" -eq 2 ] && [ -d "$(lockdir)" ]'
"${WT}" start eps >/dev/null 2>&1; finish_change "${M}/.worktrees/eps" eps e.txt
run in_dir "${M}/.worktrees/eps" "${WT}" integrate
check "integrate is BLOCKED (not hung) while a manual lock is held, and keeps that lock" eval '[ "${rc}" -eq 2 ] && [ ! -f e.txt ] && [ -d "$(lockdir)" ]'
run "${WT}" unlock "${token}"
check "unlock with the right token releases the lock" eval '[ "${rc}" -eq 0 ] && [ ! -d "$(lockdir)" ]'
run in_dir "${M}/.worktrees/eps" "${WT}" integrate
check "integrate works once the lock is released" eval '[ "${rc}" -eq 0 ] && [ -f e.txt ]'

echo "status"
run "${WT}" status
check "status lists state/ahead/behind/dirty per branch" contains "spec/eps.*base=develop.*state=integrated.*ahead=0.*behind=0.*dirty=no"

echo "cleanup"
run in_dir "${M}/.worktrees/alpha" "${WT}" cleanup alpha
check "cleanup refuses to run inside the worktree it removes" eval '[ "${rc}" -eq 2 ] && contains "inside"'
for c in alpha beta gamma delta eps; do "${WT}" cleanup "${c}" >/dev/null 2>&1 || echo "     cleanup ${c} failed"; done
check "cleanup removes worktrees, branches and recorded bases" eval '[ -z "$(ls .worktrees)" ] && [ -z "$(git branch --list "spec/*")" ] && [ -z "$(git config --get-regexp yuebanSpecBase)" ]'
"${WT}" start zeta >/dev/null 2>&1; implement "${M}/.worktrees/zeta" zeta z.txt
run "${WT}" cleanup zeta
check "cleanup refuses a branch that is not integrated yet" eval '[ "${rc}" -eq 2 ] && [ -d .worktrees/zeta ]'

echo "worktree directory deleted by hand"
rm -rf .worktrees/zeta
run "${WT}" start zeta
check "start re-attaches the branch (keeping its commits) when the worktree dir is gone" eval '[ "${rc}" -eq 0 ] && contains "^RECREATED=1" && contains "^AHEAD=1" && [ -f .worktrees/zeta/z.txt ]'
archive "${M}/.worktrees/zeta" zeta; in_dir .worktrees/zeta "${WT}" integrate >/dev/null 2>&1
rm -rf .worktrees/zeta
run "${WT}" cleanup zeta
check "cleanup of an integrated branch whose worktree dir is gone just deletes the branch" eval '[ "${rc}" -eq 0 ] && [ -z "$(git branch --list spec/zeta)" ]'

echo "base being rebased elsewhere"
"${WT}" start eta >/dev/null 2>&1; finish_change "${M}/.worktrees/eta" eta h.txt
git checkout -q --detach
mkdir -p "$(git rev-parse --git-dir)/rebase-merge" && echo refs/heads/develop > "$(git rev-parse --git-dir)/rebase-merge/head-name"
run in_dir .worktrees/eta "${WT}" integrate
check "integrate is BLOCKED while the base is being rebased in a worktree" eval '[ "${rc}" -eq 2 ] && contains "being rebased"'
rm -rf "$(git rev-parse --git-dir)/rebase-merge"

echo "base branch not checked out anywhere, and a tag named like it"
git tag develop develop~1
run in_dir .worktrees/eta "${WT}" integrate
check "integrate moves the base ref directly when no worktree has it" eval '[ "${rc}" -eq 0 ] && [ "$(git rev-parse refs/heads/develop)" = "$(git -C .worktrees/eta rev-parse HEAD)" ]'
check "the report counts the branch's commits, not the same-named tag's" contains "(2 commit(s) from spec/eta)"
git tag -d develop >/dev/null; git checkout -q develop

echo "review fixes"
cd "${M}" || exit 1
add_change mu; add_change nu; add_change xi; add_change omi
"${WT}" start mu >/dev/null 2>&1; "${WT}" start nu >/dev/null 2>&1
( cd .worktrees/mu && echo mu > same.txt && git add same.txt && git commit -q -m mu ) && archive "${M}/.worktrees/mu" mu
( cd .worktrees/nu && echo nu > same.txt && git add same.txt && git commit -q -m nu ) && archive "${M}/.worktrees/nu" nu
in_dir .worktrees/mu "${WT}" integrate >/dev/null 2>&1
run in_dir .worktrees/nu "${WT}" integrate
check "NEEDS_REBASE tells to rebase onto refs/heads/<base>" eval '[ "${rc}" -eq 3 ] && contains "git rebase refs/heads/develop"'
( cd .worktrees/nu && git rebase -q refs/heads/develop >/dev/null 2>&1 )
run in_dir .worktrees/nu "${WT}" integrate
check "integrate in a worktree stuck mid-rebase says so" eval '[ "${rc}" -eq 2 ] && contains "rebase is still in progress"'
run "${WT}" start nu
check "start reports STATE=rebasing for a worktree stuck mid-rebase" eval '[ "${rc}" -eq 0 ] && contains "^STATE=rebasing" && contains "^WORKTREE=${M}/.worktrees/nu"'
run "${WT}" status
check "status lists the rebasing branch" contains "spec/nu.*state=rebasing"
( cd .worktrees/nu && git rebase --abort )
"${WT}" start xi >/dev/null 2>&1
git branch -q other develop && git checkout -q other && echo foreign > foreign.txt && git add foreign.txt && git commit -q -m foreign && git checkout -q develop
( cd .worktrees/xi && git rebase -q other && echo xi > xi.txt && git add xi.txt && git commit -q -m xi ) && archive "${M}/.worktrees/xi" xi
run in_dir .worktrees/xi "${WT}" integrate
check "integrate refuses commits that belong to another local branch" eval '[ "${rc}" -eq 2 ] && contains "other local branches" && [ ! -f foreign.txt ]'
"${WT}" start omi >/dev/null 2>&1
printf 'local-secret\n' > .env.local && printf '.env.local\n' >> .git/info/exclude
( cd .worktrees/omi && printf 'template\n' > .env.local && git add -f .env.local && git commit -q -m tmpl ) && archive "${M}/.worktrees/omi" omi
run in_dir .worktrees/omi "${WT}" integrate
check "integrate refuses to overwrite an ignored local file in the base worktree" eval '[ "${rc}" -eq 2 ] && contains ".env.local" && [ "$(cat .env.local)" = local-secret ]'
touch .worktrees.tmp; add_change pi
mv .worktrees .worktrees.real && mv .worktrees.tmp .worktrees
run "${WT}" start pi
check "start with .worktrees as a plain file leaves no branch behind" eval '[ "${rc}" -eq 2 ] && [ -z "$(git branch --list spec/pi)" ]'
rm .worktrees && mv .worktrees.real .worktrees
run "${WT}" unlock ""
check "unlock with an empty token is a usage error" eval '[ "${rc}" -eq 1 ]'
run env YUEBAN_WT_LOCK_WAIT=abc "${WT}" status
check "a non-numeric YUEBAN_WT_LOCK_WAIT is a usage error, not a hang" eval '[ "${rc}" -eq 1 ]'
run "${WT}" start -x
check "a change name starting with - is rejected" eval '[ "${rc}" -eq 1 ]'
run "${WT}" start a/b
check "a change name with / is rejected" eval '[ "${rc}" -eq 1 ] && contains "Invalid change name"'

echo "submodules"
S="${TMP}/sub src"; mkdir -p "${S}" && git -C "${S}" init -q -b develop && git -C "${S}" commit -q --allow-empty -m sub
P="${TMP}/super repo"; mkdir -p "${P}" && cd "${P}" || exit 1
git init -q -b develop && printf '.worktrees/\n' > .gitignore && git add .gitignore && git commit -q -m init
git -c protocol.file.allow=always submodule add -q "${S}" sub && git commit -q -m sub
add_change iota; add_change kappa
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
run "${WT}" start iota
check "start initializes submodules in the new worktree" eval '[ "${rc}" -eq 0 ] && [ -n "$(git -C .worktrees/iota/sub rev-parse HEAD 2>/dev/null)" ]'
finish_change "${P}/.worktrees/iota" iota i.txt
touch .worktrees/iota/sub/build.out
run in_dir .worktrees/iota "${WT}" integrate
check "integrate ignores untracked build output inside a submodule" eval '[ "${rc}" -eq 0 ] && [ -f i.txt ]'
run "${WT}" cleanup iota
check "cleanup removes a worktree that has submodules" eval '[ "${rc}" -eq 0 ] && [ ! -e .worktrees/iota ]'
"${WT}" start kappa >/dev/null 2>&1
( cd .worktrees/kappa/sub && git commit -q --allow-empty -m local-only )
( cd .worktrees/kappa && git add sub ) && finish_change "${P}/.worktrees/kappa" kappa k.txt
run in_dir .worktrees/kappa "${WT}" integrate
check "integrate refuses a branch that changes a submodule pointer" eval '[ "${rc}" -eq 2 ] && contains "submodule pointers" && [ ! -f k.txt ]'
git -C .worktrees/kappa reset -q --hard develop   # branch back on develop; the submodule keeps its local-only commit
run "${WT}" cleanup kappa
check "cleanup refuses a worktree whose submodule has commits off the recorded pointer" eval '[ "${rc}" -eq 2 ] && [ -d .worktrees/kappa ]'
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

echo "not ignored"
Q="${TMP}/no ignore"; mkdir -p "${Q}" && cd "${Q}" && git init -q -b main && git commit -q --allow-empty -m init && add_change lambda
run "${WT}" start lambda
check "start blocks when .worktrees/ is not git-ignored" eval '[ "${rc}" -eq 2 ] && contains "not git-ignored" && [ ! -e .worktrees ]'

[ "${fail}" -eq 0 ] && echo "ALL PASSED" || echo "SOME CASES FAILED"
exit "${fail}"
