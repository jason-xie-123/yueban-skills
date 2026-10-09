#!/usr/bin/env bash
# selftest.sh — regression tests for wt.sh against throwaway repos in a temp dir (paths with spaces, one repo with a
# submodule): start/resume, integrate as a fast-forward of the base worktree, NEEDS_REBASE after a parallel change
# landed first, two integrates racing, the integration lock, its tokens and its contract with other tools (owner line,
# taking over a dead holder's lock), cleanup, and the edge cases found in review (deleted worktree dirs, a base being
# rebased, a tag named like the base, submodule changes, bad arguments),
# and the .yueban/config hooks with submodules on the change branch: landing submodule commits, NEEDS_MERGE, undoing
# submodule moves when the parent's fails, hook failures, leftover branches and unsupported submodule changes.
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

echo "lock contract"
fake_lock() { # fake_lock <owner line>: the lock as another tool following the contract would hold it
  mkdir "$(lockdir)" && printf '%s\n' "$1" > "$(lockdir)/owner"
}
sh -c 'exit 0' & dead_pid=$!; wait "${dead_pid}"
run "${WT}" lock
token="$(printf '%s\n' "${out}" | sed -n 's/^LOCK_TOKEN=//p')"
check "lock writes the documented owner line (token, then an empty pid)" eval 'head -1 "$(lockdir)/owner" | grep -q "^token=${token} pid= "'
"${WT}" unlock "${token}" >/dev/null 2>&1
fake_lock "token=other pid=$$ since=x holder=another tool"
run "${WT}" lock --wait 0
check "a lock another tool holds with a live pid is waited for, not taken over" eval '[ "${rc}" -eq 2 ] && contains "still held" && grep -q "^token=other " "$(lockdir)/owner"'
rm -rf "$(lockdir)"
fake_lock "token=other pid= since=x holder=another tool (manual)"
run "${WT}" lock --wait 0
check "a lock with no pid is never taken over" eval '[ "${rc}" -eq 2 ] && grep -q "^token=other " "$(lockdir)/owner"'
rm -rf "$(lockdir)"
fake_lock "token=dead pid=${dead_pid} since=x holder=a tool that died"
run "${WT}" lock --wait 0
token="$(printf '%s\n' "${out}" | sed -n 's/^LOCK_TOKEN=//p')"
check "a lock whose holder process is gone is taken over" eval '[ "${rc}" -eq 0 ] && grep -q "^token=${token} " "$(lockdir)/owner" && [ ! -d "$(lockdir).takeover" ]'
"${WT}" unlock "${token}" >/dev/null 2>&1
fake_lock "token=dead pid=${dead_pid} since=x holder=a tool that died"
mkdir "$(lockdir).takeover" && touch -t 202001010000 "$(lockdir).takeover"
run "${WT}" lock --wait 0
token="$(printf '%s\n' "${out}" | sed -n 's/^LOCK_TOKEN=//p')"
check "a takeover directory left by a waiter that died is cleared, then the lock is taken over" eval '[ "${rc}" -eq 0 ] && [ -n "${token}" ] && [ ! -d "$(lockdir).takeover" ]'
"${WT}" unlock "${token}" >/dev/null 2>&1
check "the lock is free after the contract cases" eval '[ ! -d "$(lockdir)" ]'

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

echo "hooks and submodules on the change branch"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
for s in a b; do
  mkdir -p "${TMP}/src ${s}" && git -C "${TMP}/src ${s}" init -q -b develop && git -C "${TMP}/src ${s}" commit -q --allow-empty -m "${s} init"
done
H="${TMP}/hooked repo"; mkdir -p "${H}" && cd "${H}" || exit 1
git init -q -b develop && printf '.worktrees/\n' > .gitignore
git submodule add -q "${TMP}/src a" "sub a" && git submodule add -q "${TMP}/src b" b
mkdir -p .yueban hooks
# The hooks put every submodule of the change worktree on the change branch, as worktrees of the main worktree's
# submodule repositories, and log what they were given. Flag files in .git make them fail on demand.
cat > hooks/setup.sh <<'HOOK'
#!/usr/bin/env bash
set -eu
G="$(git -C "${YUEBAN_MAIN_WT}" rev-parse --absolute-git-dir)"
echo "setup|${YUEBAN_WT_PATH}|${YUEBAN_WT_BRANCH}|${YUEBAN_WT_BASE}|${YUEBAN_CHANGE}|${YUEBAN_MAIN_WT}|${PWD}" >> "${G}/hook.log"
[ ! -f "${G}/fail-setup" ]
branch="$(git branch --show-current)"
git config -z -f .gitmodules --get-regexp '^submodule\..*\.path$' | while IFS= read -r -d '' rec; do p="${rec#*$'\n'}"
  [ -e "${p}/.git" ] && continue
  repo="${YUEBAN_MAIN_WT}/${p}"; git -C "${repo}" worktree prune
  if git -C "${repo}" show-ref -q --verify "refs/heads/${branch}"; then git -C "${repo}" worktree add -q "${PWD}/${p}" "${branch}"
  else git -C "${repo}" worktree add -q -b "${branch}" "${PWD}/${p}" "$(git rev-parse "HEAD:${p}")"; fi
done
[ ! -f "${G}/fail-setup-late" ]
HOOK
cat > hooks/teardown.sh <<'HOOK'
#!/usr/bin/env bash
set -eu
G="$(git -C "${YUEBAN_MAIN_WT}" rev-parse --absolute-git-dir)"
echo "teardown|${YUEBAN_CHANGE}" >> "${G}/hook.log"
[ ! -f "${G}/fail-teardown" ]
git config -z -f .gitmodules --get-regexp '^submodule\..*\.path$' | while IFS= read -r -d '' rec; do p="${rec#*$'\n'}"
  if [ -f "${p}/.git" ]; then git -C "${YUEBAN_MAIN_WT}/${p}" worktree remove --force "${PWD}/${p}"; fi
done
[ ! -f "${G}/fail-teardown-late" ]
HOOK
chmod +x hooks/*.sh
printf '[worktree]\n\tsetup = hooks/setup.sh\n\tteardown = hooks/teardown.sh\n' > .yueban/config
git add -A && git commit -q -m init
for c in h1 h2 h3 h4 h5 h6 h7 h8 h9 r1 r2 r3 r4 r5 r6 r7; do add_change "${c}"; done
G="$(git rev-parse --absolute-git-dir)"
sub_commit() { # sub_commit <dir> <file>: a commit inside a submodule checkout
  ( cd "$1" && echo "$2" > "$2" && git add "$2" && git commit -q -m "sub: $2" )
}
record() { ( cd "$1" && git add "sub a" b && git commit -q -m "record pointers" ); }

run "${WT}" start h1
check "start runs the setup hook and puts the submodules on the change branch" eval '[ "${rc}" -eq 0 ] && [ "$(git -C ".worktrees/h1/sub a" branch --show-current)" = spec/h1 ] && [ "$(git -C .worktrees/h1/b branch --show-current)" = spec/h1 ]'
check "start lists the submodules on the change branch" eval 'contains "^SUBMODULE_ON_BRANCH=sub a" && contains "^SUBMODULE_ON_BRANCH=b"'
check "the setup hook gets the YUEBAN_* variables and runs in the worktree" eval 'grep -qxF "setup|${H}/.worktrees/h1|spec/h1|develop|h1|${H}|${H}/.worktrees/h1" "${G}/hook.log"'
out="$("${WT}" start h1 2>/dev/null)"
check "hook output goes to stderr, not into the KEY=value stdout" eval '! printf "%s" "${out}" | grep -q "^HOOK" && contains "^STATE=in_progress"'
W="${H}/.worktrees/h1"
sub_commit "${W}/sub a" a1.txt; finish_change "${W}" h1 h1.txt
run in_dir "${W}" "${WT}" integrate
check "integrate refuses a submodule commit the parent has not recorded" eval '[ "${rc}" -eq 2 ] && contains "does not record yet"'
record "${W}"; echo dirty > "${W}/sub a/a1.txt"
run in_dir "${W}" "${WT}" integrate
check "integrate refuses a dirty submodule" eval '[ "${rc}" -eq 2 ] && contains "submodule sub a has uncommitted changes"'
git -C "${W}/sub a" checkout -q -- a1.txt
run in_dir "${W}" "${WT}" integrate
check "integrate lands the submodule commit on its develop, then the parent" eval '[ "${rc}" -eq 0 ] && contains "INTEGRATED_SUBMODULE: sub a develop" && [ "$(git -C "${H}/sub a" rev-parse develop)" = "$(git -C "${W}/sub a" rev-parse HEAD)" ] && [ "$(git rev-parse develop)" = "$(git -C "${W}" rev-parse HEAD)" ]'
check "the main worktree is clean afterwards, submodule files included" eval '[ -z "$(git status --porcelain)" ] && [ -f "${H}/sub a/a1.txt" ] && [ -f "${H}/h1.txt" ]'
check "an untouched submodule's develop did not move" eval '[ "$(git -C "${H}/b" rev-parse develop)" = "$(git -C "${H}/b" rev-parse HEAD)" ] && [ -z "$(git -C "${H}/b" log --oneline develop -1 --grep sub:)" ]'
run in_dir "${W}" "${WT}" integrate
check "integrating again reports ALREADY_INTEGRATED" eval '[ "${rc}" -eq 0 ] && contains ALREADY_INTEGRATED'
run "${WT}" cleanup h1
check "cleanup runs the teardown hook and deletes the change branch in the submodules too" eval '[ "${rc}" -eq 0 ] && [ ! -e "${W}" ] && grep -qxF "teardown|h1" "${G}/hook.log" && [ -z "$(git -C "${H}/sub a" branch --list spec/h1)" ] && [ -z "$(git -C "${H}/b" branch --list spec/h1)" ] && [ -z "$(git branch --list spec/h1)" ]'

echo "two changes in the same submodule"
"${WT}" start h2 >/dev/null 2>&1; "${WT}" start h3 >/dev/null 2>&1
W2="${H}/.worktrees/h2"; W3="${H}/.worktrees/h3"
sub_commit "${W2}/sub a" a2.txt; record "${W2}"; finish_change "${W2}" h2 h2.txt
sub_commit "${W3}/sub a" a3.txt; record "${W3}"; finish_change "${W3}" h3 h3.txt
in_dir "${W2}" "${WT}" integrate >/dev/null 2>&1
run in_dir "${W3}" "${WT}" integrate
check "the second one needs a merge in the submodule and the parent" eval '[ "${rc}" -eq 3 ] && contains "NEEDS_MERGE" && contains "^SYNC=merge" && contains "^SYNC_REPO=sub a" && contains "^SYNC_REPO=\.$" && contains "  sub a/a2.txt" && contains "  h2.txt"'
check "NEEDS_MERGE lists the submodule before the parent" eval '[ "$(printf "%s\n" "${out}" | sed -n "s/^SYNC_REPO=//p" | tr "\n" "|")" = "sub a|.|" ]'
git -C "${W3}/sub a" merge -q --no-edit refs/heads/develop
( cd "${W3}" && git merge -q --no-edit refs/heads/develop >/dev/null 2>&1 )
run "${WT}" start h3
check "start reports STATE=merging while the parent merge has conflicts" eval '[ "${rc}" -eq 0 ] && contains "^STATE=merging"'
run in_dir "${W3}" "${WT}" integrate
check "integrate refuses while a merge is in progress" eval '[ "${rc}" -eq 2 ] && contains "merge is still in progress"'
( cd "${W3}" && git add "sub a" && git commit -q --no-edit )
run in_dir "${W3}" "${WT}" integrate
check "after merging, both submodule changes land" eval '[ "${rc}" -eq 0 ] && [ -f "${H}/sub a/a2.txt" ] && [ -f "${H}/sub a/a3.txt" ] && [ -z "$(git status --porcelain)" ]'
for c in h2 h3; do "${WT}" cleanup "${c}" >/dev/null 2>&1 || echo "     cleanup ${c} failed"; done

echo "submodule base moved on its own"
"${WT}" start h4 >/dev/null 2>&1; W4="${H}/.worktrees/h4"
sub_commit "${W4}/sub a" a4.txt; record "${W4}"; finish_change "${W4}" h4 h4.txt
sub_commit "${H}/sub a" direct.txt
run in_dir "${W4}" "${WT}" integrate
check "a submodule base that moved alone needs a merge only there" eval '[ "${rc}" -eq 3 ] && contains "^SYNC_REPO=sub a" && ! contains "^SYNC_REPO=\.$"'
git -C "${W4}/sub a" merge -q --no-edit refs/heads/develop && record "${W4}"
run in_dir "${W4}" "${WT}" integrate
check "integrate refuses while the main worktree has an unrecorded submodule commit" eval '[ "${rc}" -eq 2 ] && contains "uncommitted tracked changes" && [ ! -f "${H}/sub a/a4.txt" ]'
git add "sub a" && git commit -q -m "record direct"
run in_dir "${W4}" "${WT}" integrate
check "after recording it, the parent needs a merge too" eval '[ "${rc}" -eq 3 ] && contains "^SYNC_REPO=\.$"'
( cd "${W4}" && git merge -q --no-edit refs/heads/develop >/dev/null 2>&1; git add "sub a" && git commit -q --no-edit ) >/dev/null 2>&1
run in_dir "${W4}" "${WT}" integrate
check "then it lands" eval '[ "${rc}" -eq 0 ] && [ -f "${H}/sub a/a4.txt" ] && [ -f "${H}/sub a/direct.txt" ] && [ -z "$(git status --porcelain)" ]'

echo "parent landing fails after the submodule moved"
"${WT}" start h5 >/dev/null 2>&1; W5="${H}/.worktrees/h5"
sub_commit "${W5}/sub a" a5.txt; sub_commit "${W5}/b" b5.txt; record "${W5}"; finish_change "${W5}" h5 h5.txt
olda="$(git -C "${H}/sub a" rev-parse develop)"; oldb="$(git -C "${H}/b" rev-parse develop)"; oldp="$(git rev-parse develop)"
touch "${G}/index.lock"
run in_dir "${W5}" "${WT}" integrate
rm -f "${G}/index.lock"
check "a failed parent fast-forward moves every submodule base back" eval '[ "${rc}" -eq 2 ] && contains "back where it was" && [ "$(git -C "${H}/sub a" rev-parse develop)" = "${olda}" ] && [ "$(git -C "${H}/b" rev-parse develop)" = "${oldb}" ] && [ "$(git rev-parse develop)" = "${oldp}" ]'
check "the submodule checkouts are back on the old commit, clean" eval '[ "$(git -C "${H}/sub a" rev-parse HEAD)" = "${olda}" ] && [ ! -f "${H}/sub a/a5.txt" ] && [ -z "$(git status --porcelain)" ]'
check "the lock is released after the rollback" eval '[ ! -d "$(lockdir)" ]'
run in_dir "${W5}" "${WT}" integrate
check "retrying lands everything" eval '[ "${rc}" -eq 0 ] && [ -f "${H}/sub a/a5.txt" ] && [ -f "${H}/b/b5.txt" ] && [ -z "$(git status --porcelain)" ]'

echo "hook failures"
touch "${G}/fail-teardown"
run "${WT}" cleanup h5
check "a failing teardown hook removes nothing" eval '[ "${rc}" -eq 2 ] && contains "teardown hook failed" && [ -d "${W5}" ] && [ -n "$(git branch --list spec/h5)" ]'
rm -f "${G}/fail-teardown"
run "${WT}" cleanup h4
check "cleanup works again once the teardown hook passes" eval '[ "${rc}" -eq 0 ] && [ ! -e "${W4}" ]'
"${WT}" cleanup h5 >/dev/null 2>&1
touch "${G}/fail-setup"
run "${WT}" start h6
check "a failing setup hook on a new worktree leaves nothing behind" eval '[ "${rc}" -eq 2 ] && contains "removed again" && [ ! -e .worktrees/h6 ] && [ -z "$(git branch --list spec/h6)" ] && [ -z "$(git -C "${H}/sub a" branch --list spec/h6)" ] && [ -z "$(git config --get branch.spec/h6.yuebanSpecBase)" ]'
check "the teardown hook ran to undo the failed setup" eval 'grep -qxF "teardown|h6" "${G}/hook.log"'
rm -f "${G}/fail-setup"
"${WT}" start h6 >/dev/null 2>&1; touch "${G}/fail-setup"
run "${WT}" start h6
check "a failing setup hook on a reused worktree keeps it" eval '[ "${rc}" -eq 2 ] && contains "kept as they are" && [ -d .worktrees/h6 ] && [ -n "$(git branch --list spec/h6)" ]'
rm -f "${G}/fail-setup"
run "${WT}" cleanup h6
check "cleanup of a change with no commits works and drops the submodule branches" eval '[ "${rc}" -eq 0 ] && [ -z "$(git -C "${H}/sub a" branch --list spec/h6)" ]'

echo "leftovers and unsupported submodule changes"
git -C "${H}/sub a" branch spec/h7
run "${WT}" start h7
check "start refuses when a submodule already has the change branch" eval '[ "${rc}" -eq 2 ] && contains "already has a branch spec/h7" && [ -z "$(git branch --list spec/h7)" ]'
git -C "${H}/sub a" branch -D spec/h7 >/dev/null
"${WT}" start h7 >/dev/null 2>&1; W7="${H}/.worktrees/h7"
( cd "${W7}" && mkdir extra && git update-index --add --cacheinfo "160000,$(git -C b rev-parse HEAD),extra" && git commit -q -m "add gitlink" )
finish_change "${W7}" h7 h7.txt
run in_dir "${W7}" "${WT}" integrate
check "integrate refuses a branch that adds a submodule" eval '[ "${rc}" -eq 2 ] && contains "adds, removes or replaces the submodule extra"'
"${WT}" start h8 >/dev/null 2>&1; W8="${H}/.worktrees/h8"
git -C "${H}/b" worktree remove --force "${W8}/b" && git clone -q "${TMP}/src b" "${W8}/b" && git -C "${W8}/b" checkout -q -b spec/h8
sub_commit "${W8}/b" b8.txt; ( cd "${W8}" && git add b && git commit -q -m "record b" ); finish_change "${W8}" h8 h8.txt
run in_dir "${W8}" "${WT}" integrate
check "integrate refuses a submodule that is a separate clone, not a worktree of the main one" eval '[ "${rc}" -eq 2 ] && contains "is not a worktree of the repository"'
run "${WT}" cleanup h8
check "cleanup refuses an unlanded change (submodule commits included)" eval '[ "${rc}" -eq 2 ] && [ -d "${W8}" ]'

echo "worktree directory deleted by hand, with hooks"
"${WT}" start h9 >/dev/null 2>&1; W9="${H}/.worktrees/h9"
sub_commit "${W9}/sub a" a9.txt; record "${W9}"
rm -rf "${W9}"
run "${WT}" start h9
check "start re-creates the worktree and the setup hook brings the submodule branch back" eval '[ "${rc}" -eq 0 ] && contains "^RECREATED=1" && [ "$(git -C "${W9}/sub a" branch --show-current)" = spec/h9 ] && [ -f "${W9}/sub a/a9.txt" ]'
archive "${W9}" h9
run in_dir "${W9}" "${WT}" integrate
check "and it lands" eval '[ "${rc}" -eq 0 ] && [ -f "${H}/sub a/a9.txt" ]'
rm -rf "${W9}"
run "${WT}" cleanup h9
check "cleanup with the worktree dir gone skips teardown and still drops every branch" eval '[ "${rc}" -eq 0 ] && [ -z "$(git -C "${H}/sub a" branch --list spec/h9)" ] && [ -z "$(git branch --list spec/h9)" ]'

echo "review fixes: submodules"
cd "${H}" || exit 1
git config diff.ignoreSubmodules all
"${WT}" start r1 >/dev/null 2>&1; R1="${H}/.worktrees/r1"
sub_commit "${R1}/b" r1.txt; record "${R1}"; finish_change "${R1}" r1 r1.txt
run in_dir "${R1}" "${WT}" integrate
check "diff.ignoreSubmodules=all cannot hide a submodule change from integrate" eval '[ "${rc}" -eq 0 ] && contains "INTEGRATED_SUBMODULE: b" && [ -f "${H}/b/r1.txt" ]'
git config --unset diff.ignoreSubmodules
"${WT}" cleanup r1 >/dev/null 2>&1
"${WT}" start r2 >/dev/null 2>&1; R2="${H}/.worktrees/r2"
( cd "${R2}/b" && mkdir nested && git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),nested" && git commit -q -m nested )
record "${R2}"; finish_change "${R2}" r2 r2.txt
run in_dir "${R2}" "${WT}" integrate
check "integrate refuses a change to a nested submodule" eval '[ "${rc}" -eq 2 ] && contains "nested submodule inside b"'
"${WT}" start r3 >/dev/null 2>&1; R3="${H}/.worktrees/r3"
sub_commit "${R3}/sub a" r3.txt; record "${R3}"; finish_change "${R3}" r3 r3.txt
git -C "${H}/sub a" checkout -q --detach
run in_dir "${R3}" "${WT}" integrate
check "integrate refuses when the main checkout's submodule is not on the base" eval '[ "${rc}" -eq 2 ] && contains "is not on develop" && [ -z "$(git status --porcelain)" ]'
git -C "${H}/sub a" checkout -q develop
printf 'SECRET=local\n' > "${H}/sub a/.env" && printf '.env\n' >> "$(git -C "${H}/sub a" rev-parse --git-common-dir)/info/exclude"
( cd "${R3}/sub a" && printf 'SECRET=committed\n' > .env && git add -f .env && git commit -q -m env ) && record "${R3}"
run in_dir "${R3}" "${WT}" integrate
check "integrate refuses to overwrite an ignored local file in the main checkout's submodule" eval '[ "${rc}" -eq 2 ] && contains "${H}/sub a" && contains ".env" && [ "$(cat "${H}/sub a/.env")" = SECRET=local ]'
rm -f "${H}/sub a/.env"
"${WT}" start r4 >/dev/null 2>&1; R4="${H}/.worktrees/r4"
run in_dir "${R3}" "${WT}" integrate
check "and lands once it is out of the way" eval '[ "${rc}" -eq 0 ] && [ -f "${H}/sub a/r3.txt" ]'
finish_change "${R4}" r4 r4.txt
"${WT}" cleanup r3 >/dev/null 2>&1
( cd "${R4}" && git rebase -q refs/heads/develop )
run in_dir "${R4}" "${WT}" integrate
check "after a rebase, a submodule behind the recorded commit is fast-forwarded, not recorded back" eval '[ "${rc}" -eq 0 ] && contains "fast-forwarded submodule sub a" && [ "$(git -C "${R4}/sub a" rev-parse HEAD)" = "$(git -C "${H}/sub a" rev-parse develop)" ] && [ -f "${H}/sub a/r3.txt" ]'
"${WT}" cleanup r4 >/dev/null 2>&1

echo "review fixes: hooks"
touch "${G}/fail-setup-late"
run "${WT}" start r5
check "a setup hook failing after it made submodule branches leaves none behind" eval '[ "${rc}" -eq 2 ] && [ -z "$(git -C "${H}/sub a" branch --list spec/r5)" ] && [ -z "$(git -C "${H}/b" branch --list spec/r5)" ]'
rm -f "${G}/fail-setup-late"
run "${WT}" start r5
check "so start works on the next try" eval '[ "${rc}" -eq 0 ] && contains "^SUBMODULE_ON_BRANCH=b"'
touch "${G}/fail-teardown-late"
run "${WT}" cleanup r5
check "a teardown hook failing halfway keeps the worktree" eval '[ "${rc}" -eq 2 ] && [ -d .worktrees/r5 ] && [ ! -e ".worktrees/r5/sub a/.git" ]'
rm -f "${G}/fail-teardown-late"
run "${WT}" cleanup r5
check "cleanup can be retried after a teardown that removed submodule checkouts" eval '[ "${rc}" -eq 0 ] && [ ! -e .worktrees/r5 ] && [ -z "$(git -C "${H}/b" branch --list spec/r5)" ]'
cp .yueban/config "${TMP}/config.bak" && printf '\tprotect = main develop\n' >> .yueban/config
run "${WT}" start r6
check "start refuses a base listed in worktree.protect" eval '[ "${rc}" -eq 2 ] && contains "worktree.protect" && [ -z "$(git branch --list spec/r6)" ]'
cp "${TMP}/config.bak" .yueban/config
cd "${M}" || exit 1
mkdir -p .yueban && printf '[worktree]\n\tsetup = true\n' > .yueban/config && add_change rho
run "${WT}" start rho
check "start refuses when .yueban/config exists in the main worktree but is not committed" eval '[ "${rc}" -eq 2 ] && contains "not committed" && [ -z "$(git branch --list spec/rho)" ]'
rm -rf .yueban
add_change sigma; "${WT}" start sigma >/dev/null 2>&1
mkdir -p .yueban && printf '[worktree]\n\tsetup = true\n' > .yueban/config && git add .yueban && git commit -q -m "add config"
run "${WT}" start sigma
check "a change started before .yueban/config was committed can still be resumed (with a warning)" eval '[ "${rc}" -eq 0 ] && contains "predates .yueban/config"'
git rm -q -r .yueban && git commit -q -m "drop config"

echo "review fixes: round 3"
cd "${H}" || exit 1
"${WT}" start r7 >/dev/null 2>&1; R7="${H}/.worktrees/r7"
printf 'SECRET\n' > "${H}/ünï.env" && printf 'ünï.env\n' >> "${G}/info/exclude"
( cd "${R7}" && printf 'new\n' > ünï.env && git add -f ünï.env && git commit -q -m env ) && finish_change "${R7}" r7 r7.txt
touch "${R7}/b/build.out"
run in_dir "${R7}" "${WT}" integrate
check "integrate refuses to overwrite an ignored file with a non-ASCII name" eval '[ "${rc}" -eq 2 ] && contains "would overwrite" && [ "$(cat "${H}/ünï.env")" = SECRET ]'
rm -f "${H}/ünï.env"
run in_dir "${R7}" "${WT}" integrate
check "untracked build output in a submodule does not block integrate" eval '[ "${rc}" -eq 0 ] && [ -f "${H}/r7.txt" ]'
cp .yueban/config "${TMP}/config.bak" && printf '\tprotect = *\n' >> .yueban/config && touch "${H}/develop"
add_change r8
run "${WT}" start r8
check "worktree.protect values are not glob-expanded" eval '[ "${rc}" -eq 0 ]'
cp "${TMP}/config.bak" .yueban/config && rm -f "${H}/develop"

echo "unreadable config"
R="${TMP}/bad config"; mkdir -p "${R}" && cd "${R}" || exit 1
git init -q -b main && printf '.worktrees/\n' > .gitignore && mkdir .yueban && printf '[worktree\nsetup = x\n' > .yueban/config
git add -A && git commit -q -m init && add_change mu
run "${WT}" start mu
check "an unreadable .yueban/config blocks start and leaves nothing behind" eval '[ "${rc}" -eq 2 ] && contains "cannot read" && [ -z "$(git branch --list spec/mu)" ] && [ ! -e .worktrees/mu ]'
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

echo "not ignored"
Q="${TMP}/no ignore"; mkdir -p "${Q}" && cd "${Q}" && git init -q -b main && git commit -q --allow-empty -m init && add_change lambda
run "${WT}" start lambda
check "start blocks when .worktrees/ is not git-ignored" eval '[ "${rc}" -eq 2 ] && contains "not git-ignored" && [ ! -e .worktrees ]'

[ "${fail}" -eq 0 ] && echo "ALL PASSED" || echo "SOME CASES FAILED"
exit "${fail}"
