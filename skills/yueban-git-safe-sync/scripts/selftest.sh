#!/usr/bin/env bash
# selftest.sh — regression tests for sync.sh against a throwaway superproject (two submodules, local bare remotes,
# a second clone standing in for another machine) in a temp dir. Covers the submodule-pointer cases: push refusing
# a recorded pointer that would not be on the submodule's remote, and merge-base merging submodules first and
# recording the merged submodule commits in the superproject's merge. Touches nothing outside the temp dir.
# Usage: selftest.sh      Exit code: 0 = all passed, 1 = a case failed.
set -uo pipefail

SYNC="$(cd "$(dirname "$0")" && pwd -P)/sync.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sync-selftest.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fail=0
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@"; then echo "ok   ${label}"; else echo "FAIL ${label}"; fail=1; fi
}
contains() { printf '%s' "${out}" | grep -q -- "$1"; }
g() { git -c protocol.file.allow=always "$@"; }
commit_in() { # commit_in <repo> <file> <content> <message>
  echo "$3" > "$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -q -m "$4"
}
is_ancestor() { git -C "$1" merge-base --is-ancestor "$2" "$3"; }

cd "${TMP}" || exit 1
for r in sa sb main; do git init -q --bare -b develop "remote-$r.git"; done
for r in sa sb; do
  git clone -q "remote-$r.git" "seed-$r" 2>/dev/null
  commit_in "seed-$r" f "$r" init && git -C "seed-$r" push -q origin develop
done
git clone -q remote-main.git dev 2>/dev/null
git -C dev commit -q --allow-empty -m init
(cd dev && g submodule add -q -b develop "${TMP}/remote-sa.git" sa && g submodule add -q -b develop "${TMP}/remote-sb.git" sb)
git -C dev commit -q -m subs && git -C dev push -q origin develop
for p in sa sb; do git -C "dev/$p" checkout -q -B develop origin/develop; done

# Machine A works on branch "feat" everywhere.
g clone -q --recurse-submodules remote-main.git A 2>/dev/null
A="${TMP}/A"
for p in . sa sb; do
  git -C "A/$p" checkout -q -B develop origin/develop
  git -C "A/$p" checkout -q -b feat && git -C "A/$p" push -q -u origin feat
done

echo "push"
commit_in A/sa f a1 "sa work"
X="$(git -C A/sa rev-parse HEAD)"
git -C A add sa && git -C A commit -q -m "bump sa"
commit_in A/sa f a2 "sa work (amended)" >/dev/null
git -C A/sa reset -q --soft HEAD~2 && git -C A/sa commit -q -m "sa work v2"
out="$(cd A && bash "${SYNC}" push 2>&1)"; rc=$?
check "push exits 2 when a recorded pointer would not be on the submodule remote" [ "${rc}" -eq 2 ]
check "push names the commit, path and pointer" contains "records sa at ${X:0:8}"
check "push pushed nothing" eval '! git -C remote-sa.git cat-file -e "$(git -C A/sa rev-parse HEAD)" 2>/dev/null'

git -C A add sa && git -C A commit -q -m "record sa v2"
out="$(cd A && bash "${SYNC}" push 2>&1)"; rc=$?
check "push succeeds once the tip's pointer is published by the push itself" [ "${rc}" -eq 0 ]
check "push still notes the older commit with the unpublished pointer" contains "older superproject commit .* records sa at ${X:0:8}"
check "superproject's pushed pointer exists on the submodule remote" \
  git -C remote-sa.git cat-file -e "$(git -C remote-main.git rev-parse feat:sa)^{commit}"

commit_in A/sb f b1 "sb work"
out="$(cd A && bash "${SYNC}" push --dry-run 2>&1)"; rc=$?
check "push notes a submodule ahead of the superproject's recorded pointer" contains "NOTE: sb is at"
check "that note does not block" [ "${rc}" -eq 0 ]
(cd A && bash "${SYNC}" push >/dev/null 2>&1)

echo "merge-base"
# develop moves both submodule pointers; feat moved sa (both sides) and sb (feat side only, not recorded).
commit_in dev/sa g d1 "sa on develop" && git -C dev/sa push -q origin develop
commit_in dev/sb g d1 "sb on develop" && git -C dev/sb push -q origin develop
git -C dev add sa sb && git -C dev commit -q -m "bump on develop" && git -C dev push -q origin develop
out="$(cd A && bash "${SYNC}" merge-base develop 2>&1)"; rc=$?
check "merge-base succeeds when both sides moved a submodule pointer" [ "${rc}" -eq 0 ]
order="$(printf '%s\n' "${out}" | sed -n 's/^-- \([^:]*\): merging.*/\1/p' | paste -sd ' ' -)"
check "submodules are merged before the superproject" [ "${order}" = "sa sb ." ]
for p in sa sb; do
  check "superproject merge records $p's merged HEAD" eval '[ "$(git -C A rev-parse HEAD:'"$p"')" = "$(git -C A/'"$p"' rev-parse HEAD)" ]'
  check "recorded $p contains develop's $p pointer" is_ancestor "A/$p" "$(git -C A rev-parse origin/develop:"$p")" "$(git -C A rev-parse HEAD:"$p")"
done
check "superproject is clean after merge-base" eval '[ -z "$(git -C A status --porcelain)" ]'
check "every repo stayed on feat" eval 'for p in . sa sb; do [ "$(git -C "A/$p" branch --show-current)" = feat ] || exit 1; done'
(cd A && bash "${SYNC}" push >/dev/null 2>&1)

echo "merge-base with a submodule conflict"
commit_in dev/sa f dev-side "sa conflict on develop" && git -C dev/sa push -q origin develop
git -C dev add sa && git -C dev commit -q -m "bump sa again" && git -C dev push -q origin develop
commit_in A/sa f feat-side "sa conflict on feat"
git -C A add sa && git -C A commit -q -m "bump sa on feat"
before="$(git -C A rev-parse HEAD)"
out="$(cd A && bash "${SYNC}" merge-base develop 2>&1)"; rc=$?
check "merge-base stops on the submodule conflict" eval '[ "${rc}" -eq 2 ] && contains "sa — merge of origin/develop"'
check "superproject was not merged before the submodule" eval '[ "$(git -C A rev-parse HEAD)" = "${before}" ] && ! git -C A rev-parse -q --verify MERGE_HEAD >/dev/null'
echo resolved > A/sa/f && git -C A/sa add f && git -C A/sa commit -q --no-edit
out="$(cd A && bash "${SYNC}" merge-base develop 2>&1)"; rc=$?
check "re-run merges the superproject after the submodule is resolved" [ "${rc}" -eq 0 ]
check "superproject records the resolved submodule merge" eval '[ "$(git -C A rev-parse HEAD:sa)" = "$(git -C A/sa rev-parse HEAD)" ]'

echo
echo "scenarios (selftest-scenarios.sh)"
scenarios_out="$(cd / && bash "$(dirname "${SYNC}")/selftest-scenarios.sh" "${SYNC}" 2>&1)" || fail=1
printf '%s\n' "${scenarios_out}" | grep -v -e '^passed [0-9]'

echo
if [ "${fail}" -eq 0 ]; then echo "all passed"; else echo "some cases FAILED"; fi
exit "${fail}"

