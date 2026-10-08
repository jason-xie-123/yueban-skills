#!/usr/bin/env bash
# selftest-scenarios.sh — scenario regression tests for flow.sh, run by selftest.sh. Each scenario builds a fresh
# throwaway superproject (sub-a, sub-b, deprecated/old; bare local remotes; a second clone as another machine) in a
# temp dir: worktree.sh-style worktrees, branches only on origin, cleanup safety (unmerged commits on origin, partial
# deletes), submodule.recurse=true, uninitialised submodules, running from a submodule, paths with spaces.
# Touches nothing outside the temp dir.
# Usage: selftest-scenarios.sh [path/to/flow.sh]     Exit code: 0 = all passed, 1 = a case failed.
set -uo pipefail

FLOW_SH="${1:-$(cd "$(dirname "$0")" && pwd -P)/flow.sh}"
flow() { /bin/bash "${FLOW_SH}" "$@"; }   # macOS bash 3.2 explicitly
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/flow-extra.XXXXXX")"
ROOT="$(cd "${ROOT}" && pwd -P)"
trap 'rm -rf "${ROOT}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fail=0; npass=0; nfail=0
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@"; then echo "ok   ${label}"; npass=$((npass + 1)); else echo "FAIL ${label}"; fail=1; nfail=$((nfail + 1)); fi
}
contains() { printf '%s' "${out}" | grep -q -- "$1"; }
on() { [ "$(git -C "$1" branch --show-current)" = "$2" ]; }
has_branch() { git -C "$1" rev-parse -q --verify "refs/heads/$2" >/dev/null; }
all_on() { local b="$1" r; shift; for r in "$@"; do on "${r}" "${b}" || return 1; done; }

n=0
fresh() { # fresh superproject in $M, remotes in $T
  n=$((n + 1)); T="${ROOT}/s${n}"; mkdir -p "${T}"; cd "${T}" || exit 1
  local r
  for r in sub-a sub-b old; do
    git init -q --bare -b develop "r-${r}.git"
    git clone -q "r-${r}.git" "src-${r}" 2>/dev/null
    git -C "src-${r}" commit -q --allow-empty -m "${r} init" && git -C "src-${r}" push -q origin HEAD:develop
  done
  git init -q --bare -b develop "r main.git"
  git clone -q "r main.git" "m1" 2>/dev/null
  M="${T}/m1"; cd "${M}" || exit 1
  git commit -q --allow-empty -m init
  git -c protocol.file.allow=always submodule add -q "${T}/r-sub-a.git" sub-a
  git -c protocol.file.allow=always submodule add -q "${T}/r-sub-b.git" sub-b
  git -c protocol.file.allow=always submodule add -q "${T}/r-old.git" deprecated/old
  git commit -q -m subs && git push -q origin HEAD:develop
  for r in sub-a sub-b deprecated/old; do git -C "${r}" checkout -q -B develop origin/develop; git -C "${r}" remote set-head origin develop; done
  git remote set-head origin develop
}
clone2() { # second machine in $M2, submodules on develop
  M2="${T}/m2"
  git -c protocol.file.allow=always clone -q --recurse-submodules "${T}/r main.git" "${M2}" 2>/dev/null
  git -C "${M2}/sub-a" checkout -q -B develop origin/develop
  git -C "${M2}/sub-b" checkout -q -B develop origin/develop
}
push_all() { local r; for r in sub-a sub-b .; do git -C "$r" push -q -u origin "$1"; done; }
merge_all_into_develop() { local r; for r in sub-a sub-b .; do git -C "$r" checkout -q develop && git -C "$r" merge -q --ff-only "$1" && git -C "$r" push -q origin develop; done; }

echo "== worktrees: superproject worktree with per-submodule worktrees (worktree.sh style)"
fresh
git worktree add -q -b wt/topic "${T}/wt main" develop
for s in sub-a sub-b; do rmdir "${T}/wt main/${s}"; git -C "${s}" worktree add -q -b wt/topic "${T}/wt main/${s}" develop; done
flow start feat-x develop >/dev/null 2>&1
for r in . sub-a sub-b; do git -C "$r" checkout -q develop; done
cd "${T}/wt main"
out="$(flow sync feat-x 2>&1)"; rc=$?
check "sync inside a superproject worktree whose submodules are worktrees: no false positive" eval '[ "${rc}" -eq 0 ] && all_on feat-x . sub-a sub-b'
cd "${M}"
out="$(flow sync feat-x 2>&1)"; rc=$?
check "main checkout: branch held by a submodule worktree inside the other superproject worktree is BLOCKED" eval '[ "${rc}" -eq 2 ] && contains "sub-a can.t switch.*wt main/sub-a" && all_on develop . sub-a sub-b'
cd "${T}/wt main"; for r in . sub-a sub-b; do git -C "$r" checkout -q wt/topic; done
cd "${M}"; flow sync feat-x >/dev/null 2>&1
cd "${T}/wt main"
out="$(flow sync feat-x 2>&1)"; rc=$?
check "superproject worktree: branch held by the main checkout's submodule (.git/modules/<name>) is BLOCKED" eval '[ "${rc}" -eq 2 ] && contains "sub-a can.t switch" && all_on wt/topic . sub-a sub-b'
check "that BLOCKED message names the submodule's working tree, not its git dir" eval '! contains "\.git/modules/sub-a"'
cd "${M}"

echo "== second machine: branch only on origin"
fresh
flow start wt/feat-o develop >/dev/null 2>&1
git -C sub-a commit -q --allow-empty -m a1; git add sub-a; git commit -q -m bump
push_all wt/feat-o
clone2; cd "${M2}"
out="$(flow sync wt/feat-o 2>&1)"; rc=$?
check "sync tracks origin-only branch in every active repo" eval '[ "${rc}" -eq 0 ] && all_on wt/feat-o . sub-a sub-b'
check "tracked branch has origin as upstream" eval '[ "$(git -C sub-a rev-parse --abbrev-ref wt/feat-o@{upstream})" = origin/wt/feat-o ]'
check "deprecated submodule untouched" eval '[ -z "$(git -C deprecated/old branch --show-current)" ] || ! on deprecated/old wt/feat-o'
check "sync leaves no pointer drift after tracking" eval '[ -z "$(git status --porcelain)" ]'
out="$(flow finish wt/feat-o 2>&1)"; rc=$?
check "finish on second machine falls back to origin/HEAD with a note" eval '[ "${rc}" -eq 0 ] && contains "no recorded base"'
git -C "${M2}/sub-a" commit -q --allow-empty -m m2; git -C "${M2}/sub-a" push -q
cd "${M}"; git -C sub-a commit -q --allow-empty -m m1-diverge
out="$(flow sync wt/feat-o 2>&1)"; rc=$?
check "diverged sync is BLOCKED and nothing switches" eval '[ "${rc}" -eq 2 ] && contains "diverged" && all_on wt/feat-o . sub-a sub-b'

echo "== start: rerun, change-id characters, old config key"
fresh
flow start feat-e develop >/dev/null 2>&1
out="$(flow start feat-e develop 2>&1)"; rc=$?
check "start re-run when every repo is already on it exits 0 under bash 3.2" eval '[ "${rc}" -eq 0 ] && contains "already on it"'
for r in . sub-a sub-b; do git -C "$r" branch -q other develop; done
out="$(flow start feat-e other 2>&1)"; rc=$?
check "start re-run with a different base is BLOCKED (no mixed bases)" eval '[ "${rc}" -eq 2 ] && contains "started from .develop., not .other."'
check "...and changes no recorded base" eval '[ "$(git config --get flow-base.feat-e.base)" = develop ] && [ "$(git -C sub-b config --get flow-base.feat-e.base)" = develop ]'
for r in . sub-a sub-b; do git -C "$r" checkout -q develop; done
for id in "v1.2-fix" "Feat/Upper.Case" "wt/a/b-c"; do
  out="$(flow start "${id}" develop 2>&1)"; rc=$?
  check "start '${id}' records base in every repo" eval '[ "${rc}" -eq 0 ] && [ "$(git config --get "flow-base.${id}.base")" = develop ] && [ "$(git -C sub-b config --get "flow-base.${id}.base")" = develop ]'
  out="$(flow finish "${id}" --cleanup 2>&1)"; rc=$?
  check "cleanup '${id}' removes branch and record" eval '[ "${rc}" -eq 0 ] && ! has_branch sub-a "${id}" && [ -z "$(git config --get "flow-base.${id}.base")" ] && [ -z "$(git -C sub-a config --get "flow-base.${id}.base")" ]'
done
for id in "-bad" "a..b" "has space"; do
  out="$(flow start "${id}" develop 2>&1)"; rc=$?
  check "invalid change-id '${id}' changes nothing" eval '[ "${rc}" -ne 0 ] && all_on develop . sub-a sub-b'
done
for r in . sub-a sub-b; do git -C "$r" checkout -q -b feat-old develop; git -C "$r" config flow-base.feat-old develop; done
out="$(flow finish feat-old 2>&1)"
check "old flow-base.<id> key is still read" eval '! contains "no recorded base"'
flow finish feat-old --cleanup >/dev/null 2>&1
check "old flow-base.<id> key is removed by cleanup" eval '[ -z "$(git config --get flow-base.feat-old)" ] && [ -z "$(git -C sub-a config --get flow-base.feat-old)" ]'
flow start a develop >/dev/null 2>&1
for r in . sub-a sub-b; do git -C "$r" checkout -q develop; done
flow start a.base develop >/dev/null 2>&1
flow finish a.base --cleanup >/dev/null 2>&1
check "cleanup of change-id 'a.base' keeps the base record of change-id 'a' (old-key fallback collision)" eval '[ "$(git config --get flow-base.a.base)" = develop ]'

echo "== cleanup safety"
fresh
flow start feat-a develop >/dev/null 2>&1
git -C sub-a commit -q --allow-empty -m a1; git add sub-a; git commit -q -m bump
push_all feat-a
clone2; (cd "${M2}" && flow sync feat-a >/dev/null 2>&1 && git -C sub-a commit -q --allow-empty -m "m2 extra" && git -C sub-a push -q)
extra="$(git -C "${M2}/sub-a" rev-parse HEAD)"
cd "${M}"; merge_all_into_develop feat-a
out="$(flow finish feat-a --cleanup 2>&1)"; rc=$?
check "cleanup never deletes origin/<id> holding commits not merged into base" eval '[ -n "$(git -C "${T}/r-sub-a.git" branch --contains "${extra}")" ]'
check "...and BLOCKS instead" eval '[ "${rc}" -eq 2 ]'

fresh
flow start feat-u develop >/dev/null 2>&1
git -C sub-a commit -q --allow-empty -m u1
out="$(flow finish feat-u --cleanup 2>&1)"; rc=$?
check "cleanup refuses unmerged local work and deletes nothing" eval '[ "${rc}" -eq 2 ] && has_branch . feat-u && has_branch sub-a feat-u && has_branch sub-b feat-u'

fresh
flow start feat-b develop >/dev/null 2>&1
push_all feat-b
git -C sub-b commit -q --allow-empty -m "local only"
merge_all_into_develop feat-b
out="$(flow finish feat-b --cleanup 2>&1)"; rc=$?
check "cleanup: feature merged+pushed via base but ahead of its own upstream -> all-or-nothing (no partial delete)" eval '{ [ "${rc}" -eq 0 ] && ! has_branch sub-b feat-b; } || { has_branch . feat-b && has_branch sub-a feat-b; }'

fresh
flow start feat-c develop >/dev/null 2>&1
git -C sub-b commit -q --allow-empty -m c1
merge_all_into_develop feat-c
git -C sub-b checkout -q -b other develop~1
out="$(flow finish feat-c --cleanup 2>&1)"; rc=$?
check "cleanup: submodule on an unrelated branch, never-pushed merged feature -> all-or-nothing" eval '{ [ "${rc}" -eq 0 ] && ! has_branch sub-b feat-c; } || { has_branch . feat-c && has_branch sub-a feat-c; }'

fresh
flow start feat-d develop >/dev/null 2>&1
git -C sub-a commit -q --allow-empty -m d1
git -C sub-a push -q origin feat-d:develop    # merged on origin only (PR), feature never pushed
out="$(flow finish feat-d 2>&1)"
check "report says a branch merged into origin/<base> is merged" eval 'contains "origin/develop"'
out="$(flow finish feat-d --cleanup 2>&1)"; rc=$?
check "cleanup NOTE path (merged on origin only) completes or deletes nothing" eval '{ [ "${rc}" -eq 0 ] && ! has_branch sub-a feat-d; } || has_branch . feat-d'

echo "== submodule.recurse=true (common user setting)"
fresh
flow start feat-r develop >/dev/null 2>&1
git -C sub-a commit -q --allow-empty -m r1; git add sub-a; git commit -q -m bump
git checkout -q develop
git config submodule.recurse true
out="$(flow sync feat-r 2>&1)"; rc=$?
check "sync never leaves a submodule in detached HEAD, even with submodule.recurse=true" eval 'all_on feat-r . sub-a sub-b'
git config --unset submodule.recurse

echo "== repo discovery"
fresh
git worktree add -q -b wt/raw "${T}/wt raw" develop     # submodules not initialised: empty dirs
cd "${T}/wt raw"
out="$(flow status 2>&1)"
check "status does not report an uninitialised (empty) submodule dir as on the superproject's branch" eval '! contains "sub-a: branch=wt/raw"'
out="$(flow start wt/x wt/raw 2>&1)"; rc=$?
check "start BLOCKS up front on an uninitialised submodule (no half-done start)" eval '[ "${rc}" -eq 2 ] && contains "BLOCKED" && on . wt/raw'
cd "${M}"
cd sub-a
out="$(flow start feat-in develop 2>&1)"; rc=$?
cd "${M}"
check "running from inside a submodule acts on the whole superproject (or refuses)" eval '{ [ "${rc}" -eq 0 ] && all_on feat-in . sub-a sub-b; } || { [ "${rc}" -ne 0 ] && all_on develop . sub-a sub-b; }'
for r in . sub-a sub-b; do git -C "$r" checkout -q develop; done

fresh
git init -q --bare -b develop "${T}/r-sp.git"; git clone -q "${T}/r-sp.git" "${T}/src-sp" 2>/dev/null
git -C "${T}/src-sp" commit -q --allow-empty -m sp; git -C "${T}/src-sp" push -q origin HEAD:develop
git -c protocol.file.allow=always submodule add -q "${T}/r-sp.git" "my sub"; git commit -q -m sp; git push -q origin HEAD:develop
git -C "my sub" checkout -q -B develop origin/develop
out="$(flow start feat-sp develop 2>&1)"; rc=$?
check "submodule path with a space is handled" eval '[ "${rc}" -eq 0 ] && on "my sub" feat-sp'

echo "== start when the branch already exists on origin"
fresh
flow start feat-s develop >/dev/null 2>&1
git -C sub-a commit -q --allow-empty -m s1
push_all feat-s
clone2; cd "${M2}"
out="$(flow start feat-s develop 2>&1)"; rc=$?
check "start BLOCKS (use sync) when origin/<id> already exists" eval '[ "${rc}" -eq 2 ] && all_on develop . sub-a sub-b'
cd "${M}"

echo "== sync preflight vs worktree in the middle of a rebase"
fresh
flow start feat-p develop >/dev/null 2>&1
for r in . sub-a sub-b; do git -C "$r" checkout -q develop; done
git -C sub-b worktree add -q "${T}/rb" feat-p
git -C "${T}/rb" commit -q --allow-empty -m x
git -C "${T}/rb" rebase -q --exec false HEAD~1 >/dev/null 2>&1
out="$(flow sync feat-p 2>&1)"; rc=$?
check "sync BLOCKS up front when a rebasing worktree holds the branch (no partial switch)" eval '[ "${rc}" -eq 2 ] && all_on develop . sub-a'

echo
echo "passed=${npass} failed=${nfail}"
[ "${fail}" -eq 0 ] && echo "ALL PASSED" || echo "SOME CASES FAILED"
exit "${fail}"
