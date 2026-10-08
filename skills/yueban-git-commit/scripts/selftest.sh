#!/usr/bin/env bash
# selftest.sh — checks the shell snippets in ../SKILL.md against throwaway repos (local bare remotes, a superproject
# with two submodules, a second clone, a parent worktree whose submodule is itself a worktree). Every snippet runs
# under both zsh and bash, since agents run them in the user's login shell. Some cases pin down plain git behavior
# the skill's rules rely on (why it forbids `git add -A` with submodules in status, or `git add -p`).
# Touches nothing outside the temp dir. Keep the snippets below identical to SKILL.md when editing either.
# Usage: selftest.sh      Exit code: 0 = all passed, 1 = a case failed.
set -uo pipefail

TMP="$(mktemp -d "${TMPDIR:-/tmp}/commit-selftest.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir "${TMP}/zdot" && export ZDOTDIR="${TMP}/zdot"   # keep the user's zsh rc files out of the test
G=(git -c protocol.file.allow=always)
fail=0
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@"; then echo "ok   ${label}"; else echo "FAIL ${label}"; fail=1; fi
}
# both <dir> <snippet>: run the snippet in zsh and in bash from <dir>; outputs in ${oz} / ${ob}
both() {
  oz="$(cd "$1" && zsh -c "$2" 2>&1)"; rz=$?
  ob="$(cd "$1" && bash -c "$2" 2>&1)"; rb=$?
}
has() { grep -q -- "$2" <<<"$1"; }   # no pipe: grep -q + pipefail would turn SIGPIPE into a failure
both_have() { has "${oz}" "$1" && has "${ob}" "$1"; }
both_lack() { ! has "${oz}" "$1" && ! has "${ob}" "$1"; }
staged() { [ -n "$(git -C "${P}" diff --cached --name-only -- "$1")" ]; }

# Verbatim snippets from SKILL.md (placeholders substituted with "a").
DETACHED='git symbolic-ref -q --short HEAD || echo "Detached HEAD — switch to or create a branch first"'
CASE2='git -C a fetch --quiet --prune origin || echo "fetch failed — cannot confirm anything is published"
rec="$(git rev-parse HEAD:a)"
cur="$(git -C a rev-parse HEAD)"
git -C a merge-base --is-ancestor "${rec}" "${cur}" && echo forward || echo "NOT forward"
git -C a branch -r --contains "${cur}" --list '"'"'origin/*'"'"''
NOTHING_STAGED='if git diff --cached --quiet; then
  echo "Nothing staged — run git add first"
  exit 1
fi'
# Staging that leaves every submodule pointer out (already used by yueban-spec-* / flow selftest).
EXCLUDE_SUBMODULES='git add -A -- . $(git config -f .gitmodules --get-regexp '"'"'\.path$'"'"' 2>/dev/null | awk '"'"'{print ":(exclude)" $2}'"'"')'

cd "${TMP}" || exit 1
for r in a b main fork; do git init -q --bare -b develop "${r}.git"; done
for r in a b; do
  git clone -q "${r}.git" "${r}src" 2>/dev/null
  git -C "${r}src" commit -q --allow-empty -m "${r} init" && git -C "${r}src" push -q origin HEAD:develop
done
git clone -q main.git p 2>/dev/null
P="${TMP}/p"; cd "${P}" || exit 1
git commit -q --allow-empty -m init
"${G[@]}" submodule add -q ../a.git a && "${G[@]}" submodule add -q ../b.git b && git commit -q -m subs
git push -q origin HEAD:develop
for s in a b; do git -C "${s}" checkout -q -B develop origin/develop; done
"${G[@]}" clone -q --recurse-submodules "${TMP}/main.git" "${TMP}/p2" 2>/dev/null
P2="${TMP}/p2"; for s in a b; do git -C "${P2}/${s}" checkout -q -B develop origin/develop; done
reset_a() { # baseline: p/a clean on origin/develop, and the parent records exactly that commit (pushed)
  git -C "${P}" reset -q
  git -C "${P}/a" checkout -q -f develop 2>/dev/null
  git -C "${P}/a" fetch -q --prune origin
  git -C "${P}/a" reset -q --hard origin/develop
  git -C "${P}/a" clean -qfd
  git -C "${P}" pull -q --ff-only --no-recurse-submodules origin develop 2>/dev/null
  if [ "$(git -C "${P}" rev-parse HEAD:a)" != "$(git -C "${P}/a" rev-parse HEAD)" ]; then
    git -C "${P}/a" fetch -q origin
    if git -C "${P}/a" merge-base --is-ancestor "$(git -C "${P}/a" rev-parse HEAD)" "$(git -C "${P}" rev-parse HEAD:a)"; then
      git -C "${P}/a" reset -q --hard "$(git -C "${P}" rev-parse HEAD:a)"; git -C "${P}/a" push -q origin develop
    else
      git -C "${P}" add a && git -C "${P}" commit -q -m "sync a" && git -C "${P}" push -q origin HEAD:develop
    fi
  fi
}
p2_bump() { # p2_bump <msg> [branch]: colleague commits on <branch> of a (default develop), pushes, records it in the parent
  local br="${2:-develop}"
  git -C "${P2}" pull -q --ff-only --no-recurse-submodules origin develop 2>/dev/null
  git -C "${P2}/a" fetch -q origin
  git -C "${P2}/a" checkout -q -B "${br}" "$(git -C "${P2}" rev-parse HEAD:a)"
  git -C "${P2}/a" commit -q --allow-empty -m "$1" && git -C "${P2}/a" push -q -f origin "${br}"
  git -C "${P2}" add a && git -C "${P2}" commit -q -m "bump a: $1" && git -C "${P2}" push -q origin develop
}

echo "== step 1: detached HEAD check"
both "${P}" "${DETACHED}"
check "on a branch: prints the branch, no warning (zsh+bash)" eval 'both_have develop && both_lack Detached'
git -C a checkout -q --detach
both "${P}/a" "${DETACHED}"
check "detached submodule: warns (zsh+bash)" both_have "Detached HEAD"
git -C a checkout -q develop

echo "== case 1: dirty submodule, HEAD == recorded pointer"
echo x > a/f
check "parent porcelain shows ' M a'" eval '[ "$(git status --porcelain)" = " M a" ]'
check "git submodule status shows no + for a dirty-only submodule" eval '! has "$(git submodule status)" "^[+]"'
check "git -C a status --porcelain is non-empty" eval '[ -n "$(git -C a status --porcelain)" ]'
git add a
check "git add a stages nothing (pointer unchanged, dirty work left out)" eval '! staged a'
git add -A
check "git add -A stages nothing for a dirty-only submodule" eval '! staged a'
reset_a

echo "== case 1 + new commit: dirty AND committed-but-unpushed"
git -C a commit -q --allow-empty -m local && echo x > a/f
git add a
check "git add a records the unpushed HEAD and leaves the dirty file out" eval 'staged a && [ -n "$(git -C a status --porcelain)" ]'
reset_a

echo "== case 2: committed but unpushed"
git -C a commit -q --allow-empty -m unpushed
both "${P}" "${CASE2}"
check "forward (zsh+bash)" eval 'both_have "^forward" && both_lack "NOT forward"'
check "not published: branch -r --contains prints nothing (zsh+bash)" eval 'both_lack origin/'
reset_a

echo "== case 2: pushed but not recorded"
git -C a commit -q --allow-empty -m pushed && git -C a push -q origin develop
both "${P}" "${CASE2}"
check "forward and published on origin/develop (zsh+bash)" eval 'both_have "^forward" && both_have "origin/develop"'
check "diff --submodule=log shows a plain forward range (no label)" eval '
  d="$(git diff --submodule=log -- a)"; has "${d}" "^Submodule a [0-9a-f]*\.\.[0-9a-f]*:$"'
reset_a

echo "== case 2: behind the recorded pointer (parent pulled, submodule not updated)"
p2_bump newer
git pull -q --ff-only origin develop 2>/dev/null   # default fetch.recurseSubmodules=on-demand also fetches a
check "submodule status shows + while behind" eval 'has "$(git submodule status)" "^[+][0-9a-f]* a "'
both "${P}" "${CASE2}"
check "NOT forward (zsh+bash)" both_have "NOT forward"
check "cur is an ancestor of rec => behind" eval 'git -C a merge-base --is-ancestor "$(git -C a rev-parse HEAD)" "$(git rev-parse HEAD:a)"'
check "diff --submodule=log labels it (rewind)" eval 'has "$(git diff --submodule=log -- a)" "(rewind)"'
echo y > unrelated.txt
git add -A
check "git add -A stages the rewind along with the file (why the skill forbids it whenever a submodule shows in status)" staged a
git reset -q
eval "${EXCLUDE_SUBMODULES}"
check "exclude-submodules staging stages the file but not the rewind" eval 'staged unrelated.txt && ! staged a'
git reset -q; rm unrelated.txt
git -C a merge -q --ff-only "$(git rev-parse HEAD:a)"
check "behind fix: merge --ff-only rec => parent clean, no commit needed" eval '[ -z "$(git status --porcelain)" ]'

echo "== case 2: recorded commit not fetched into the submodule yet"
p2_bump newest
git pull -q --ff-only --no-recurse-submodules origin develop 2>/dev/null
both "${P}" "${CASE2}"
check "fetch runs first, so rec is known and nothing fails (zsh+bash)" eval 'both_lack fatal && both_have "NOT forward"'
check "after the fetch, cur is an ancestor of rec (behind, not diverged)" eval 'git -C a merge-base --is-ancestor HEAD "$(git rev-parse HEAD:a)"'
reset_a

echo "== case 2: diverged"
git -C a reset -q --hard "$(git rev-parse HEAD:a)~1" && git -C a commit -q --allow-empty -m side
both "${P}" "${CASE2}"
check "NOT forward (zsh+bash)" both_have "NOT forward"
d="$(git diff --submodule=log -- a)"
check "diff --submodule=log shows diverged as '<old>...<new>' with no label, as SKILL.md says" has "${d}" "^Submodule a [0-9a-f]*\.\.\.[0-9a-f]*:$"
reset_a

echo "== case 2: pointer only on another branch of origin"
git -C a checkout -q -b jason && git -C a commit -q --allow-empty -m personal && git -C a push -q origin jason
both "${P}" "${CASE2}"
check "forward and published via origin/jason only (zsh+bash)" eval 'both_have "^forward" && both_have "origin/jason" && both_lack "origin/develop"'
git -C a checkout -q develop && git -C a branch -q -D jason && git push -q "${TMP}/a.git" :jason 2>/dev/null
reset_a

echo "== case 2: published only on a non-origin remote (fork)"
git -C a remote add fork "${TMP}/a.git.fork" 2>/dev/null; git clone -q --bare "${TMP}/a.git" "${TMP}/a.git.fork"
git -C a commit -q --allow-empty -m forkonly && git -C a push -q fork HEAD:forkonly
both "${P}" "${CASE2}"
check "commit that exists only on the fork is NOT reported as published (zsh+bash)" both_lack "fork/"
git -C a remote remove fork; reset_a

echo "== case 2: stale remote-tracking ref (branch deleted on origin)"
git -C a checkout -q -b tmp && git -C a commit -q --allow-empty -m onTmp && git -C a push -q origin tmp
git -C "${TMP}/asrc" push -q origin :tmp
both "${P}" "${CASE2}"
check "commit whose branch was deleted on origin is NOT reported as published (zsh+bash)" both_lack "origin/tmp"
git -C a fetch -q --prune origin
check "fetch --prune removes the stale ref, so the check prints nothing" eval '[ -z "$(git -C a branch -r --contains HEAD)" ]'
git -C a checkout -q develop && git -C a branch -q -D tmp; reset_a

echo "== case 2: fetch fails (remote unreachable)"
git -C a commit -q --allow-empty -m nofetch
url="$(git -C a remote get-url origin)"; git -C a remote set-url origin "${TMP}/missing.git"
git -C a update-ref refs/remotes/origin/develop HEAD   # pretend an earlier fetch saw it
both "${P}" "${CASE2}"
check "fetch failure is reported, so the stale published answer is not trusted (zsh+bash)" both_have "fetch failed"
git -C a remote set-url origin "${url}"; git -C a fetch -q origin "+refs/heads/develop:refs/remotes/origin/develop"; reset_a

echo "== case 2: submodule without an origin remote"
git -C a remote rename origin upstream
git -C a commit -q --allow-empty -m noorigin && git -C a push -q upstream develop
both "${P}" "${CASE2}"
check "fetch origin fails loudly, telling the agent to use the real remote name (zsh+bash)" both_have "fetch failed"
git -C a remote rename upstream origin; git -C a fetch -q origin; reset_a

echo "== new submodule (git submodule add, not committed yet)"
git init -q --bare -b develop "${TMP}/c.git"; git clone -q "${TMP}/c.git" "${TMP}/csrc" 2>/dev/null
git -C "${TMP}/csrc" commit -q --allow-empty -m c && git -C "${TMP}/csrc" push -q origin HEAD:develop
"${G[@]}" submodule add -q ../c.git c
check "porcelain shows it as added ('A  c'), not modified" eval 'has "$(git status --porcelain)" "^A  c$"'
both "${P}" "git -C c fetch --quiet --prune origin; git -C c branch -r --contains HEAD --list 'origin/*'"
check "case 3 check finds the new submodule's HEAD on origin (zsh+bash)" both_have "origin/develop"
git rm -q -f --cached c; rm -rf c .git/modules/c; git checkout -q .gitmodules

echo "== nested repo dropped in without submodule add"
git clone -q "${TMP}/c.git" d 2>/dev/null
check "porcelain shows '?? d/'" eval 'has "$(git status --porcelain)" "^?? d/$"'
git add -A 2>/dev/null
check "git add -A stages a nested repo as a pointer without .gitmodules (why the skill stops and asks)" staged d
git rm -q --cached d 2>/dev/null; rm -rf d

echo "== case 1 then case 2: commit inside a dirty submodule whose branch is behind rec on another branch"
p2_bump colleague colleague   # parent now records a commit that only origin/colleague has
git pull -q --ff-only origin develop 2>/dev/null
echo work > a/w
check "dirty => case 1" eval '[ -n "$(git -C a status --porcelain)" ]'
git -C a add w && git -C a commit -q -m mywork && git -C a push -q origin develop   # case 1: commit + push inside
both "${P}" "${CASE2}"
check "after case 1 commit+push, check 1 says NOT forward (would drop the colleague commit) (zsh+bash)" both_have "NOT forward"
git add a
check "git add a would stage that diverging pointer (why case 1 ends with case 2's checks)" staged a
git reset -q
p2_bump fix-develop   # put origin/develop's line back under the recorded pointer for later cases
git -C a fetch -q origin; git -C a reset -q --hard origin/develop; reset_a

echo "== parent worktree whose submodule is a worktree of the main checkout's submodule"
git worktree add -q -b wt/x "${TMP}/pw" develop
git -C a worktree add -q -b wt/x "${TMP}/pw/a" "$(git rev-parse HEAD:a)"
git -C b worktree add -q -b wt/x "${TMP}/pw/b" "$(git rev-parse HEAD:b)"
both "${TMP}/pw" "${DETACHED}"
check "detached check passes in the parent worktree (zsh+bash)" both_have "wt/x"
check "parent worktree sees clean submodules" eval '[ -z "$(git -C "${TMP}/pw" status --porcelain)" ]'
git -C "${TMP}/pw/a" commit -q --allow-empty -m inwt
both "${TMP}/pw" "${CASE2}"
check "case 2 in worktree: forward, not published (zsh+bash)" eval 'both_have "^forward" && both_lack "origin/"'
git -C "${TMP}/pw/a" push -q origin wt/x
both "${TMP}/pw" "${CASE2}"
check "case 2 in worktree: published on origin/wt/x after push (zsh+bash)" both_have "origin/wt/x"

echo "== step 2: staging by glob"
mkdir -p src/x && echo t > src/x/u.test.js && echo t > top.test.js
both "${P}" "git add '*.test.*'; git diff --cached --name-only; git reset -q"
check "quoted pathspec '*.test.*' stages top-level and nested files in zsh and bash alike" eval 'both_have "src/x/u.test.js" && both_have "^top.test.js"'
rm top.test.js
both "${P}" "git add '*.test.*'; git diff --cached --name-only; git reset -q"
check "quoted pathspec still works with no top-level match (zsh+bash)" eval 'both_have "src/x/u.test.js" && both_lack "no matches"'
rm -rf src

echo "== step 2: partial staging"
printf '%s\n' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 > m.txt && git add m.txt && git commit -q -m m
sed -e 's/^2$/two/' -e 's/^14$/fourteen/' m.txt > m.new && mv m.new m.txt
git add -p m.txt </dev/null >/dev/null 2>&1; rc=$?
check "git add -p without a TTY stages nothing yet exits 0 (why the skill avoids it)" eval '! staged m.txt && [ "${rc}" -eq 0 ]'
git diff -U0 -- m.txt | sed '/^@@ -14/,$d' > "${TMP}/keep.patch"
git apply --cached --unidiff-zero "${TMP}/keep.patch"
check "non-interactive alternative: diff > patch, drop a hunk, apply --cached stages only the kept hunk" eval '
  has "$(git diff --cached m.txt)" "^+two" && ! has "$(git diff --cached m.txt)" fourteen'
git reset -q; git checkout -q m.txt

echo "== step 4: empty-staging guard and heredoc message"
both "${P}" "${NOTHING_STAGED}"
check "guard fires and exits 1 when nothing is staged (zsh+bash)" eval 'both_have "Nothing staged" && [ "${rz}" -eq 1 ] && [ "${rb}" -eq 1 ]'
MSG='git commit -q --allow-empty -m "$(cat <<'"'"'EOF'"'"'
feat(x): keep $HOME, `cmd`, !bang and "quotes"

Body with $1 and ${var:h}.
EOF
)" && git log -1 --format=%B'
both "${P}" "${MSG}"
check "heredoc message is taken literally in zsh and bash" eval '[ "${oz}" = "${ob}" ] && has "${oz}" "keep \$HOME, \`cmd\`, !bang" && has "${oz}" "\${var:h}"'
git reset -q --hard HEAD~2

echo "== step 5: push"
git checkout -q -b feat1 && git commit -q --allow-empty -m f1
check "plain git push fails without an upstream" eval '! git push -q 2>/dev/null'
check "git push -u origin HEAD publishes feat1 and sets its upstream" eval '
  git push -q -u origin HEAD 2>/dev/null && [ "$(git rev-parse --abbrev-ref @{u})" = origin/feat1 ]'
git checkout -q -b feat2 origin/develop && git commit -q --allow-empty -m f2
out="$(git push 2>&1)"; rc=$?
check "branch created from origin/develop: git push refuses (name mismatch)" eval '[ "${rc}" -ne 0 ]'
check "...and git's hint suggests pushing HEAD:develop (an agent must not follow it)" has "${out}" "HEAD:develop"
git checkout -q develop

echo "== safety: base-branch lookup"
check "git ls-remote --symref origin HEAD finds the remote default branch" eval 'has "$(git ls-remote --symref origin HEAD)" "refs/heads/develop"'

[ "${fail}" -eq 0 ] && echo "ALL PASSED" || echo "SOME CASES FAILED"
exit "${fail}"
