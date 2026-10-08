#!/usr/bin/env bash
# selftest.sh — regression tests for flow.sh against a throwaway superproject (one submodule, local bare remotes,
# paths with spaces) in a temp dir, focused on branches checked out in another git worktree. Also checks the
# shell snippets the yueban-git-commit and yueban-spec-* skills rely on (detached-HEAD check, staging that
# excludes submodule pointers). Touches nothing outside the temp dir.
# Usage: selftest.sh      Exit code: 0 = all passed, 1 = a case failed.
set -uo pipefail

FLOW="$(cd "$(dirname "$0")" && pwd -P)/flow.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/flow-selftest.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fail=0
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@"; then echo "ok   ${label}"; else echo "FAIL ${label}"; fail=1; fi
}
contains() { printf '%s' "${out}" | grep -q -- "$1"; }
on() { [ "$(git -C "$1" branch --show-current)" = "$2" ]; }
has_branch() { git -C "$1" rev-parse -q --verify "refs/heads/$2" >/dev/null; }
EXCLUDE_SUBMODULES='git add -A -- . $(git config -f .gitmodules --get-regexp '"'"'\.path$'"'"' 2>/dev/null | awk '"'"'{print ":(exclude)" $2}'"'"')'

cd "${TMP}" || exit 1
git init -q --bare -b develop remote-sub.git
git init -q --bare -b develop "remote main.git"
git clone -q remote-sub.git subsrc 2>/dev/null
git -C subsrc commit -q --allow-empty -m sub && git -C subsrc push -q origin HEAD:develop
git clone -q "remote main.git" "main co" 2>/dev/null
M="${TMP}/main co"; cd "${M}" || exit 1
git commit -q --allow-empty -m init
git -c protocol.file.allow=always submodule add -q "${TMP}/remote-sub.git" sub && git commit -q -m sub
git push -q origin HEAD:develop
git -C sub checkout -q -B develop origin/develop
git remote set-head origin develop; git -C sub remote set-head origin develop

echo "flow.sh and other worktrees"
"${FLOW}" start feat1 develop >/dev/null 2>&1
check "start puts every repo on the new branch" on . feat1
git checkout -q develop; git -C sub checkout -q develop
git worktree add -q "../wt one" feat1
out="$("${FLOW}" sync feat1 2>&1)"; rc=$?
check "sync exits 2 when the branch is checked out in another worktree" [ "${rc}" -eq 2 ]
check "sync names that worktree" contains "checked out in another worktree (.*wt one)"
check "sync switched no repo" eval 'on . develop && on sub develop'

git merge -q --ff-only feat1 && git push -q origin develop
git -C sub merge -q --ff-only feat1 && git -C sub push -q origin develop
out="$("${FLOW}" finish feat1 --cleanup 2>&1)"; rc=$?
check "cleanup exits 2 while the branch is checked out in another worktree" [ "${rc}" -eq 2 ]
check "cleanup says git won't delete it" contains "git won't delete it"
check "cleanup deleted no branch" eval 'has_branch . feat1 && has_branch sub feat1'
git worktree remove "../wt one"

git checkout -q feat1
git worktree add -q "../wt two" develop
out="$("${FLOW}" finish feat1 --cleanup 2>&1)"; rc=$?
check "cleanup exits 2 when the base it must switch to is in another worktree" [ "${rc}" -eq 2 ]
check "cleanup points at that worktree" contains "Run cleanup from that worktree"
check "cleanup left this repo on its branch" on . feat1
git worktree remove "../wt two"

out="$("${FLOW}" finish feat1 --cleanup 2>&1)"; rc=$?
check "cleanup succeeds once no other worktree holds the branches" eval '[ "${rc}" -eq 0 ] && ! has_branch . feat1 && ! has_branch sub feat1'

"${FLOW}" start feat2 develop >/dev/null 2>&1
git checkout -q develop; git -C sub checkout -q develop
git worktree add -q -b unrelated "../wt three" develop   # another worktree holding an unrelated branch
out="$("${FLOW}" sync feat2 2>&1)"; rc=$?
check "sync works when other worktrees hold other branches" eval '[ "${rc}" -eq 0 ] && on . feat2 && on sub feat2'

echo "flow.sh with a change-id containing a slash"
git worktree remove "../wt three"; git branch -q -D unrelated
git checkout -q develop; git -C sub checkout -q develop
out="$("${FLOW}" start wt/feat3 develop 2>&1)"; rc=$?
check "start accepts a change-id with a slash" eval '[ "${rc}" -eq 0 ] && on . wt/feat3 && on sub wt/feat3'
check "start records the base for that change-id" eval '[ "$(git config --get flow-base.wt/feat3.base)" = develop ] && [ "$(git -C sub config --get flow-base.wt/feat3.base)" = develop ]'
out="$("${FLOW}" finish wt/feat3 2>&1)"
check "finish uses the recorded base, not the origin/HEAD fallback" eval '! contains "no recorded base"'
out="$("${FLOW}" finish wt/feat3 --cleanup 2>&1)"; rc=$?
check "cleanup works while the submodule's own checkout is on the branch" eval '! contains "another worktree"'
check "cleanup removes the branch and its recorded base" eval '[ "${rc}" -eq 0 ] && ! has_branch . wt/feat3 && [ -z "$(git config --get flow-base.wt/feat3.base)" ]'

echo "snippets used by yueban-git-commit and yueban-spec-*"
git worktree add -q --detach "../wt detached" HEAD
check "branch check passes on a branch" eval 'git symbolic-ref -q --short HEAD >/dev/null'
check "branch check fails in a detached worktree" eval '! git -C "../wt detached" symbolic-ref -q --short HEAD >/dev/null'
git -C sub commit -q --allow-empty -m bump
echo x > newfile
eval "${EXCLUDE_SUBMODULES}"
check "excluding staging stages the new file" eval '[ -n "$(git diff --cached --name-only -- newfile)" ]'
check "excluding staging leaves the submodule pointer unstaged" eval '[ -z "$(git diff --cached --name-only -- sub)" ]'
git reset -q
mkdir "${TMP}/plain" && cd "${TMP}/plain" && git init -q && echo y > f
eval "${EXCLUDE_SUBMODULES}" 2>"${TMP}/err"
check "excluding staging works without .gitmodules, silently" eval '[ -n "$(git diff --cached --name-only)" ] && [ ! -s "${TMP}/err" ]'

echo
echo "scenarios (selftest-scenarios.sh)"
scenarios_out="$(cd / && bash "$(dirname "${FLOW}")/selftest-scenarios.sh" "${FLOW}" 2>&1)" || fail=1
printf '%s\n' "${scenarios_out}" | grep -v -e '^ALL PASSED$' -e '^SOME CASES FAILED$' -e '^passed='

[ "${fail}" -eq 0 ] && echo "ALL PASSED" || echo "SOME CASES FAILED"
exit "${fail}"
