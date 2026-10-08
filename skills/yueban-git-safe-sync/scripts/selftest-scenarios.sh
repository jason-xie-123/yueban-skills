#!/usr/bin/env bash
# selftest-scenarios.sh — scenario regression tests for sync.sh, run by selftest.sh. Every case builds its own
# throwaway superproject (submodules sa, sb, deprecated/old; local bare remotes; a "dev" clone standing in for the
# other machine) under a temp dir: uninitialised submodules, first pushes and mismatched upstreams, stale remote
# branches, merge-base pointer rules and re-runs, pr via a fake gh, deprecated/ exclusion, paths with spaces,
# running from inside a submodule. Touches nothing outside the temp dir.
# Usage: selftest-scenarios.sh [path/to/sync.sh]      Exit code: 0 = all passed, 1 = a case failed.
set -uo pipefail

SYNC="${1:-$(cd "$(dirname "$0")" && pwd -P)/sync.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sync-extra.XXXXXX")"
TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fail=0; passed=0; failed=0
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@"; then echo "ok   ${label}"; passed=$((passed + 1)); else echo "FAIL ${label}"; fail=1; failed=$((failed + 1)); fi
}
contains() { printf '%s' "${out}" | grep -q -- "$1"; }
g() { git -c protocol.file.allow=always "$@"; }
commit_in() { echo "$3" > "$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -q -m "$4"; }
sha() { git -C "$1" rev-parse "$2"; }
run() { # run <dir> <args...>: sets out and rc
  local d="$1"; shift
  out="$(cd "$d" && bash "${SYNC}" "$@" 2>&1)"; rc=$?
}

# Fake gh: logs calls to $GH_LOG, `pr view` reports an open PR only for the remote named in $GH_OPEN_FOR,
# `pr create` fails if a PR was already created for that remote.
mkdir -p "${TMP}/fakebin"
cat > "${TMP}/fakebin/gh" <<'GH'
#!/usr/bin/env bash
repo="$(basename "$(git config --get remote.origin.url)")"
printf '%s %s\n' "${repo}" "$(printf '%s ' "$@" | tr '\n' ' ')" >> "${GH_LOG}"
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo '{"nameWithOwner":"x/y"}' ;;
  "pr view") [ "${repo}" = "${GH_OPEN_FOR:-}" ] && { echo "https://example/${repo}/pull/1"; exit 0; }; exit 1 ;;
  "pr create")
    grep -qx "${repo}" "${GH_LOG}.created" 2>/dev/null && { echo "a pull request already exists" >&2; exit 1; }
    echo "${repo}" >> "${GH_LOG}.created"; echo "https://example/${repo}/pull/2" ;;
esac
exit 0
GH
chmod +x "${TMP}/fakebin/gh"

# setup <name>: fresh fixture at $W; dev and A both on develop in every active submodule.
setup() {
  W="${TMP}/$1"; mkdir -p "${W}"; cd "${W}" || exit 1
  local r
  for r in sa sb old main; do git init -q --bare -b develop "remote-$r.git"; done
  for r in sa sb old; do
    git clone -q "remote-$r.git" "seed-$r" 2>/dev/null
    commit_in "seed-$r" f "$r" init && git -C "seed-$r" push -q origin develop
  done
  git clone -q remote-main.git dev 2>/dev/null
  git -C dev commit -q --allow-empty -m init
  (cd dev && g submodule add -q -b develop "${W}/remote-sa.git" sa && g submodule add -q -b develop "${W}/remote-sb.git" sb \
    && g submodule add -q "${W}/remote-old.git" deprecated/old)
  git -C dev commit -q -m subs && git -C dev push -q origin develop
  for r in sa sb; do git -C "dev/$r" checkout -q -B develop origin/develop; done
  g clone -q --recurse-submodules remote-main.git A 2>/dev/null
  for r in . sa sb; do git -C "A/$r" checkout -q -B develop origin/develop; done
}
feat_all() { local p; for p in . sa sb; do git -C "$1/$p" checkout -q -b "$2" && git -C "$1/$p" push -q -u origin "$2"; done; }
dev_bump() { # dev_bump <sub>: new commit on develop in <sub>, recorded and pushed by dev
  commit_in "dev/$1" "d-$RANDOM" x "$1 on develop" && git -C "dev/$1" push -q origin develop
  git -C dev add "$1" && git -C dev commit -q -m "bump $1 on develop" && git -C dev push -q origin develop
}

echo "status / pull"
setup status
run A status
check "status: BRANCH CHECK OK on a clean checkout" contains "BRANCH CHECK: OK"
check "status: deprecated/ submodules are not listed" eval '! contains "deprecated/old"'
git -C A/sb checkout -q -b other
run A pull
check "pull: BLOCKED when a submodule is on another branch" eval '[ "${rc}" -eq 2 ] && contains "sb is on .other."'
git -C A/sb checkout -q develop
git -C A config submodule.recurse true
dev_bump sa
before_sb="$(sha A/sb HEAD)"
run A pull
check "pull: ff superproject and submodules (submodule.recurse=true) exit 0" [ "${rc}" -eq 0 ]
check "pull: sa fast-forwarded to origin/develop and still on develop" \
  eval '[ "$(sha A/sa HEAD)" = "$(sha A/sa origin/develop)" ] && [ "$(git -C A/sa branch --show-current)" = develop ]'
commit_in A/sa local x "sa local"
dev_bump sa
run A pull
check "pull: diverged submodule is BLOCKED and nothing changed" \
  eval '[ "${rc}" -eq 2 ] && contains "diverged" && [ "$(sha A HEAD)" != "$(sha A origin/develop)" ]'

echo "detached superproject / submodule"
setup detached
git -C A checkout -q --detach
run A push --dry-run
check "push: BLOCKED with detached superproject" eval '[ "${rc}" -eq 2 ] && contains "superproject is in detached HEAD"'
git -C A checkout -q develop; git -C A/sa checkout -q --detach
run A push --dry-run
check "push: BLOCKED with detached submodule" eval '[ "${rc}" -eq 2 ] && contains "sa is in detached HEAD"'

echo "every submodule deprecated (empty arrays under set -u, bash 3.2)"
W="${TMP}/onlydep"; mkdir -p "${W}"; cd "${W}" || exit 1
for r in old main; do git init -q --bare -b develop "remote-$r.git"; done
git clone -q remote-old.git seed 2>/dev/null; commit_in seed f o init; git -C seed push -q origin develop
git clone -q remote-main.git A 2>/dev/null; git -C A commit -q --allow-empty -m init
(cd A && g submodule add -q "${W}/remote-old.git" deprecated/old); git -C A commit -q -m sub; git -C A push -q -u origin develop
for c in status pull "push --dry-run"; do
  # shellcheck disable=SC2086
  run A ${c}
  check "${c}: works with no active submodules" eval '[ "${rc}" -eq 0 ] && ! contains "unbound variable"'
done

echo "uninitialized submodule (empty directory)"
setup uninit
git clone -q remote-main.git B 2>/dev/null
(cd B && g submodule update -q --init sa); git -C B/sa checkout -q -B develop origin/develop
run B status
check "status reports the uninitialized sb as MISSING, not as on the superproject's branch" contains "sb: MISSING"
run B pull
check "pull BLOCKS on the uninitialized sb" eval '[ "${rc}" -eq 2 ] && contains "sb is not checked out"'
for p in . sa; do git -C "B/$p" checkout -q -b feat && git -C "B/$p" push -q -u origin feat; done
commit_in B top x "feat top"; git -C B push -q
commit_in dev topd y "dev top"; git -C dev push -q origin develop
run B merge-base develop
check "merge-base does not run a superproject merge through the uninitialized sb path" eval '! contains "^-- sb: merging"'

echo "base branch adds a new submodule"
setup newsub
feat_all A feat
commit_in A top t "feat top"; git -C A push -q
git init -q --bare -b develop remote-sc.git; git clone -q remote-sc.git seed-sc 2>/dev/null
commit_in seed-sc f sc init; git -C seed-sc push -q origin develop
(cd dev && g submodule add -q -b develop "${W}/remote-sc.git" sc); git -C dev commit -q -m "add sc"; git -C dev push -q origin develop
run A merge-base develop
check "merge-base takes in a submodule added on the base branch" [ "${rc}" -eq 0 ]
run A push --dry-run
check "push reports the new sc as not checked out, not as an amended/reset pointer" \
  eval 'contains "sc is not checked out" && ! contains "records sc at"'

echo "superproject push target"
setup upstream
git -C A checkout -q -b feat origin/develop    # upstream = origin/develop
git -C A push -q origin feat
for p in sa sb; do git -C "A/$p" checkout -q -b feat && git -C "A/$p" push -q -u origin feat; done
commit_in A/sa f a1 "sa work"; git -C A add sa; git -C A commit -q -m "bump sa"
dev_develop="$(sha remote-main.git develop)"
git -C A config push.default upstream
run A push
check "push never updates origin/develop when feat's upstream is origin/develop" [ "$(sha remote-main.git develop)" = "${dev_develop}" ]
check "push updates origin/feat with the superproject tip" [ "$(sha remote-main.git feat)" = "$(sha A HEAD)" ]
git -C A config --unset push.default; git -C A branch -q --unset-upstream
commit_in A/sa f a2 "sa work 2"; git -C A add sa; git -C A commit -q -m "bump sa 2"
run A push
check "push succeeds when the superproject branch has no upstream configured" eval '[ "${rc}" -eq 0 ] && [ "$(sha remote-main.git feat)" = "$(sha A HEAD)" ]'

echo "first push of a branch"
setup firstpush
for p in . sa sb; do git -C "A/$p" checkout -q -b feat; done
commit_in A/sa f a1 "sa work"; git -C A add sa; git -C A commit -q -m "bump sa"
run A push --dry-run
check "first push: nothing is pushed" eval '! git -C remote-main.git rev-parse -q --verify feat >/dev/null'
check "first push: output covers the submodules too, not only 'git push -u origin feat' for the superproject" contains "sa"

echo "push argument validation"
setup pushargs
feat_all A feat
commit_in A/sa f a1 "sa work"
before="$(sha remote-sa.git feat)"
run A push -n
check "push with an unknown option is a usage error and pushes nothing" \
  eval '[ "${rc}" -eq 1 ] && [ "$(sha remote-sa.git feat)" = "${before}" ]'

echo "stale remote-tracking ref"
setup stale
feat_all A feat
git -C A/sa checkout -q -b tmp; commit_in A/sa f x "sa experiment"; git -C A/sa push -q -u origin tmp
X="$(sha A/sa HEAD)"; git -C A/sa checkout -q feat
git -C A update-index --cacheinfo "160000,${X},sa"; git -C A commit -q -m "record experiment"
git -C remote-sa.git branch -q -D tmp; git -C remote-sa.git gc -q --prune=now
run A push --dry-run
check "push BLOCKS a tip pointer only reachable from a stale (deleted-on-remote) origin/tmp" \
  eval '[ "${rc}" -eq 2 ] && contains "records sa at ${X:0:8}"'

echo "merge-base"
setup mb
feat_all A feat
commit_in A/sa f s1 "sa s1"; git -C A add sa; git -C A commit -q -m "bump sa s1"
commit_in A/sa f2 s2 "sa s2 not recorded"
commit_in A top t "feat top"
commit_in dev topd d "dev top"; git -C dev push -q origin develop
before_sa="$(git -C A rev-parse HEAD:sa)"
run A merge-base develop
check "merge-base: only the superproject needed merging" eval '[ "${rc}" -eq 0 ] && contains "SKIP: sa" && contains "SKIP: sb"'
check "merge-base leaves a pointer only our side changed as is (no unreviewed bump to sa's unrecorded commits)" \
  [ "$(git -C A rev-parse HEAD:sa)" = "${before_sa}" ]

setup mbconflict
feat_all A feat
commit_in A/sa f s1 "sa s1"; git -C A add sa; commit_in A top feat "feat top"; git -C A push -q; git -C A/sa push -q
git -C dev/sa checkout -q -b hotfix; commit_in dev/sa h x "sa hotfix"; git -C dev/sa push -q origin hotfix
git -C dev add sa; commit_in dev top dev "dev top"; git -C dev push -q origin develop
run A merge-base develop
check "merge-base: file + gitlink conflict stops with exit 2 and the gitlink hint" \
  eval '[ "${rc}" -eq 2 ] && contains "For a gitlink still in conflict"'
check "merge-base: both conflicts are left for the user" eval '[ "$(git -C A diff --name-only --diff-filter=U | paste -sd " " -)" = "sa top" ]'
run A merge-base develop
check "merge-base: re-run while still mid-merge is BLOCKED" eval '[ "${rc}" -eq 2 ] && contains "merge in progress"'

echo "worktrees (superproject worktree + submodule worktrees of .git/modules/<name>)"
setup wt
git -C A -c submodule.recurse=false worktree add -q -b wt/x "${W}/wt" develop
for s in sa sb; do git -C "A/$s" worktree add -q -b wt/x "${W}/wt/$s" "$(git -C "${W}/wt" rev-parse "HEAD:$s")"; done
for s in sa sb; do git -C "wt/$s" push -q -u origin wt/x; done; git -C wt push -q -u origin wt/x
run wt status
check "worktree: status sees every repo on wt/x" contains "BRANCH CHECK: OK — superproject and every submodule are on 'wt/x'"
commit_in wt/sa f w1 "sa wt work"; git -C wt add sa; git -C wt commit -q -m "bump sa"
run wt push
check "worktree: push pushes sa then the superproject" \
  eval '[ "${rc}" -eq 0 ] && [ "$(sha remote-main.git wt/x)" = "$(sha wt HEAD)" ] && [ "$(sha remote-sa.git wt/x)" = "$(sha wt/sa HEAD)" ]'
dev_bump sb
run wt merge-base develop
check "worktree: merge-base merges only sb and the superproject and records sb's HEAD" \
  eval '[ "${rc}" -eq 0 ] && contains "SKIP: sa" && [ "$(git -C wt rev-parse HEAD:sb)" = "$(sha wt/sb HEAD)" ]'
check "worktree: main checkout's submodules were not moved off develop" \
  eval '[ "$(git -C A/sa branch --show-current)" = develop ] && [ "$(git -C A/sb branch --show-current)" = develop ]'

echo "pr (fake gh on PATH)"
setup pr
feat_all A feat
commit_in A/sa f s1 "sa: feature work"; git -C A add sa; git -C A commit -q -m "feat: bump sa"
dev_bump sa
(cd A && bash "${SYNC}" merge-base develop >/dev/null 2>&1 && bash "${SYNC}" push >/dev/null 2>&1)
export GH_LOG="${W}/gh.log"
out="$(cd A && PATH="${TMP}/fakebin:${PATH}" bash "${SYNC}" pr develop --draft 2>&1)"; rc=$?
check "pr: opens sa before the superproject, skips sb" \
  eval '[ "${rc}" -eq 0 ] && [ "$(grep "pr create" "${GH_LOG}" | cut -d" " -f1 | paste -sd " " -)" = "remote-sa.git remote-main.git" ] && contains "SKIP: sb"'
check "pr: --draft is passed to gh" eval '[ "$(grep "pr create" "${GH_LOG}" | grep -c -- "--draft")" -eq 2 ]'
check "pr: merge commits from merge-base are not counted (single feature commit becomes the title)" \
  eval 'contains "feat -> develop: \"sa: feature work\"" && ! contains "Merge remote-tracking branch"'
rm -f "${GH_LOG}" "${GH_LOG}.created"
out="$(cd A && GH_OPEN_FOR=remote-main.git PATH="${TMP}/fakebin:${PATH}" bash "${SYNC}" pr develop --dry-run 2>&1)"; rc=$?
check "pr: a repo with an open PR is SKIPped" eval '[ "${rc}" -eq 0 ] && contains "SKIP: .: PR already exists"'
git -C A/deprecated/old checkout -q --detach HEAD; commit_in A/deprecated/old f moved "drift" 2>/dev/null
out="$(cd A && PATH="${TMP}/fakebin:${PATH}" bash "${SYNC}" pr develop --dry-run 2>&1)"; rc=$?
check "pr: a moved deprecated/ submodule does not BLOCK the PR (deprecated is out of scope)" [ "${rc}" -eq 0 ]

echo "uninitialized submodule in pr"
setup prinit
git clone -q remote-main.git B 2>/dev/null
(cd B && g submodule update -q --init sa); git -C B/sa checkout -q -B develop origin/develop
for p in . sa; do git -C "B/$p" checkout -q -b feat && git -C "B/$p" push -q -u origin feat; done
commit_in B top x "feat top"; git -C B push -q
export GH_LOG="${W}/gh.log"
out="$(cd B && PATH="${TMP}/fakebin:${PATH}" bash "${SYNC}" pr develop 2>&1)"; rc=$?
check "pr: the uninitialized sb is BLOCKED instead of opening the superproject's PR twice" \
  eval '[ "${rc}" -eq 2 ] && contains "sb is not checked out" && ! [ -s "${GH_LOG}.created" ]'

echo "paths and cwd"
setup spaces
git init -q --bare -b develop remote-sp.git; git clone -q remote-sp.git seed-sp 2>/dev/null
commit_in seed-sp f sp init; git -C seed-sp push -q origin develop
(cd dev && g submodule add -q -b develop "${W}/remote-sp.git" "my mod"); git -C dev commit -q -m "add my mod"; git -C dev push -q origin develop
git -C "dev/my mod" checkout -q -B develop origin/develop
run dev status
check "a submodule path with a space is listed by its real path" eval 'contains "my mod: branch=develop" && ! contains "mod.path"'
setup cwd
run A/sa status
check "run from inside a submodule: operates on the superproject or refuses" eval '[ "${rc}" -ne 0 ] || contains "sb:"'

echo
echo "passed ${passed}, failed ${failed}"
exit "${fail}"
