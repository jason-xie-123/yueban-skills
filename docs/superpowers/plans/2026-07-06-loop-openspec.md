# loop-openspec Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `skills/loop-openspec/SKILL.md` — a Claude-Code-only skill that turns a large Goal into
an unattended OpenSpec loop (explore → propose/plan → apply → verify → archive, repeating until done
or paused) — and prove it actually works end-to-end against a real OpenSpec sandbox project.

**Architecture:** One self-contained `SKILL.md` file (no code, no dependencies) that documents a state
machine the agent runtime follows: a markdown state file under the target project's
`openspec/loop-engineering/<slug>/` is the single source of truth across turns; OpenSpec's own
`openspec-explore` / `openspec-propose` / `openspec-apply-change` skills are invoked for the
AI-reasoning steps; the plain `openspec archive` CLI is invoked directly for the mechanical archive
step; a fresh independent `Agent` subagent does verification; `PushNotification` fires on
pause/completion; the built-in `/loop` skill owns actual scheduling. Since the deliverable is an
instruction document rather than executable code, "testing" here means real manual dry-runs against a
throwaway OpenSpec sandbox project (built in this plan), not unit tests — each test task gives exact
commands and exact expected observations.

**Tech Stack:** Markdown (`SKILL.md`), bash, the real `@fission-ai/openspec` CLI (via `npx`), git.

**Reference:** Full design rationale lives in
`docs/superpowers/specs/2026-07-06-loop-openspec-design.md` — read it if a task here seems
under-explained.

---

### Task 1: Write `skills/loop-openspec/SKILL.md`

**Files:**
- Create: `skills/loop-openspec/SKILL.md`

- [ ] **Step 1: Create the directory and write the file with this exact content**

```bash
mkdir -p skills/loop-openspec
```

Write `skills/loop-openspec/SKILL.md`:

````markdown
---
name: loop-openspec
description: 'Turn a Goal into an unattended, self-driving OpenSpec loop: dynamically pick the next highest-value change, propose/plan it, implement it, verify it with a fresh independent agent, archive it, and decide if the whole goal is done — repeating until DONE or a guardrail pauses it for review. Claude Code only: composes with the built-in /loop skill for scheduling and PushNotification for alerts. Only use on explicit invocation — "/loop-openspec <目标...>" to kick off, "/loop-openspec continue" or bare "/loop-openspec" to resume, "/loop /loop-openspec <目标...>" for a fully unattended run. Requires the target project to already have OpenSpec initialized (openspec init, default core profile is enough) — this skill does not bootstrap OpenSpec itself.'
allowed-tools: Bash, Read, Write, Edit, Skill, Agent, PushNotification
---

# Loop OpenSpec

## Overview

Turns one big `Goal` into a self-driving loop over OpenSpec changes: EXPLORE_NEXT → PROPOSE_PLAN →
APPLY → VERIFY → ARCHIVE (or FIX_RETRY) → CHECK_GOAL_DONE, repeating until the goal's completion
criteria are met or a guardrail pauses the run for you to look at. The user states the goal,
background, and completion criteria exactly once at kickoff; every later invocation reads it back out
of a state file instead of you re-explaining anything.

## Scope & Prerequisites

- **Claude Code only.** Unattended mode composes with the built-in `/loop` skill (self-paced
  `ScheduleWakeup`); the independent verifier uses the `Agent` tool; guardrails use
  `PushNotification`. None of this has a guaranteed equivalent in Codex CLI / Gemini CLI.
- **The target project must already have OpenSpec initialized** on its default profile. Check before
  doing anything else:

  ```bash
  test -d openspec || { echo "OpenSpec not found. Run: openspec init --tools claude (or npx @fission-ai/openspec@latest init --tools claude), then re-invoke this skill."; exit 1; }
  for s in openspec-explore openspec-propose openspec-apply-change; do
    test -d ".claude/skills/$s" || { echo "Missing .claude/skills/$s — re-run: openspec update --force"; exit 1; }
  done
  ```

  If either check fails, tell the user exactly what to run and stop. Do not attempt to run
  `openspec init` on their behalf.
- **No git worktree isolation** — this runs directly in the current working directory. Don't
  hand-edit the same project while an unattended run is in progress.
- **One active goal per project at a time.** This skill doesn't support running two goals
  concurrently.

## Invocation

```
# Kickoff, unattended (wraps in the built-in /loop skill so it self-schedules):
/loop /loop-openspec 目标：<一句话目标>。背景：<约束、现状、期望方向——一次性交代完>。完成标准：<怎么算彻底做完了>

# Kickoff, manual step-by-step (you re-invoke each round yourself):
/loop-openspec 目标：<...>。背景：<...>。完成标准：<...>

# Resume — reads everything back out of the state file, no re-explaining:
/loop-openspec continue
/loop-openspec

# Append new context to the active run without restarting it:
/loop-openspec <要追加的新背景或说明>
```

## Step 1 — Find or create the state file

```bash
ls openspec/loop-engineering/*/state.md 2>/dev/null
```

- **If the user's message is a kickoff (contains 目标/背景/完成标准, i.e. new goal text) AND no
  `state.md` matches this goal**: this is `INIT`. Pick a short (3-6 word) kebab-case English slug
  that summarizes the goal regardless of what language it was given in (e.g. a Chinese goal about
  rate limiting → `add-rate-limiting`). Create `openspec/loop-engineering/<slug>/state.md` using the
  template in "State file format" below, filling in Goal / Background / Completion Criteria
  verbatim. Go to `EXPLORE_NEXT`.
- **If the user's message is a kickoff and a `state.md` with that same slug already exists**: append
  the new text to that file's `# Appended Context` section (don't overwrite Goal/Background/
  Completion Criteria), then proceed as `continue` below.
- **If the user's message is `continue` / bare / arbitrary extra context (no 目标/背景/完成标准)**:
  look for exactly one `state.md` with `status: running`.
  - Zero found: tell the user there's no active `loop-openspec` run in this project and stop.
  - Exactly one found: if there's extra context in the message, append it to `# Appended Context`,
    then resume from wherever the Iteration Log left off.
  - More than one found: list their `goal_slug`s and ask the user which one to continue.

## State file format

Location: `openspec/loop-engineering/<goal-slug>/state.md`.

```markdown
---
goal_slug: add-rate-limiting
status: running        # running | done | paused
consecutive_failures: 0
total_changes_completed: 0
max_changes: 20         # override at kickoff if the user asked for a different cap
---

# Goal
<verbatim>

# Background / Constraints
<verbatim>

# Completion Criteria
<verbatim>

# Appended Context
<anything appended by later invocations, in order, never overwritten>

# Iteration Log
| # | Change | Phase | Verifier | Notes |
|---|---|---|---|---|

# Carry-forward notes from last EXPLORE
<short notes for the next EXPLORE_NEXT step>
```

## Step 2 — Run one iteration of the state machine

`EXPLORE_NEXT → PROPOSE_PLAN → APPLY → VERIFY → (ARCHIVE | FIX_RETRY) → CHECK_GOAL_DONE`

### EXPLORE_NEXT

Invoke the `openspec-explore` skill (`Skill({skill: "openspec-explore"})`) with this framing: given
the Goal, Completion Criteria, Iteration Log, and Carry-forward notes from the state file, and the
current state of the repo, what is the single next most valuable OpenSpec change? There is no fixed
upfront roadmap — re-derive this fresh every iteration. Come out of this step with a short change
name and a 2-4 sentence rationale.

### PROPOSE_PLAN

Invoke the `openspec-propose` skill (`Skill({skill: "openspec-propose"})`) for that change name.
Review the generated `proposal.md` / spec deltas / `design.md` / `tasks.md` under
`openspec/changes/<change-name>/`. OpenSpec's propose step produces all four in one pass — there is
no separate later "plan" step.

**Commit:** once the spec artifacts look right, invoke the `git-commit` skill to commit them —
`docs: propose <change-name>`.

### APPLY

Invoke the `openspec-apply-change` skill (`Skill({skill: "openspec-apply-change"})`) for
`<change-name>`, which works through `tasks.md` implementing each unchecked task.

**Commit:** after each completed task (or small group of directly-related tasks), invoke
`git-commit` — `feat(<scope>): implement task N of <change-name>`. Don't wait until every task in the
change is done to make the first commit.

### VERIFY

This skill does **not** depend on OpenSpec's own `openspec-verify-change` skill — that only exists if
the target project's global OpenSpec config has been switched to `profile: custom` with `verify`
added to `workflows`, which is not something this skill should require the user to set up (confirmed:
the default `core` profile does not include it). Instead, spawn one fresh, independent subagent with
the `Agent` tool — plain `general-purpose`, **not** a fork, since it must not share the APPLY step's
context — using this exact prompt (fill in `<change-name>`):

```
Verify the OpenSpec change "<change-name>" at openspec/changes/<change-name>/ against its own
artifacts. Read proposal.md, the spec deltas, design.md, and tasks.md in that folder. Then look at
git log / git diff for the commits made for this change to see what was actually implemented. If the
project has a test suite or build command, run it.

Report every issue you find, each tagged CRITICAL, WARNING, or SUGGESTION:
- CRITICAL: a task checked off in tasks.md that wasn't actually done, a spec requirement that isn't
  met, a failing test/build, or code that contradicts design.md.
- WARNING: a task still unchecked, a minor deviation from spec that doesn't break functionality,
  missing but non-critical test coverage.
- SUGGESTION: style or clarity improvements, optional follow-ups.

End your report with exactly one line: "VERDICT: PASS" if you found zero CRITICAL issues, or
"VERDICT: FAIL" if you found one or more.
```

Map the result to `loop-openspec`'s own gate: **PASS** iff the subagent's last line is
`VERDICT: PASS` (zero CRITICAL issues). **FAIL** otherwise. Log the CRITICAL/WARNING/SUGGESTION
items in the Iteration Log's Notes column either way.

**Caveat to remember and mention to the user if asked:** this verifier is the same underlying model
in a fresh context, not an independently-trained checker. It reliably catches missed tasks and
obvious test/build failures; it does not reliably catch a misunderstanding the APPLY step and this
verifier both happen to share. Treat it as a real but partial safety net.

### ARCHIVE (on PASS)

Run the plain CLI directly instead of an AI skill — archiving is mechanical once VERIFY has already
gated it:

```bash
openspec archive <change-name> --yes --json
```

(Add `--skip-specs` only if this change has no spec deltas — e.g. pure docs/infra changes.) This
moves the change folder to `openspec/changes/archive/YYYY-MM-DD-<change-name>/` and updates main
specs in the same step.

**Commit:** invoke `git-commit` — `chore: archive <change-name>`.

Then: reset `consecutive_failures` to 0, increment `total_changes_completed`, append a row to the
Iteration Log (`archived`, `PASS`), go to `CHECK_GOAL_DONE`.

### FIX_RETRY (on FAIL)

Increment `consecutive_failures` in the state file frontmatter.

- **`< 3`**: revise the implementation using the verifier's CRITICAL feedback, invoke `git-commit` —
  `fix(<scope>): address verifier feedback on <change-name>` — then go back to `VERIFY`.
- **`== 3`**: set `status: paused` in the state file, append a row to the Iteration Log
  (`fix_retry (3/3)`, `FAIL`), then:

  ```
  PushNotification({
    message: "loop-openspec paused: <change-name> failed verification 3x — <one-line reason>. Needs your review.",
    status: "proactive"
  })
  ```

  End the turn with the sentinel line `LOOP_STATUS: PAUSED` (see "Composing with /loop" below).
  Don't continue looping.

### CHECK_GOAL_DONE

Read the Completion Criteria and the full Iteration Log. Judge whether the goal is now satisfied.

- **Criteria met** → set `status: done` in the state file, then:

  ```
  PushNotification({
    message: "loop-openspec done: '<goal_slug>' complete — <N> changes archived. Review before merging further.",
    status: "proactive"
  })
  ```

  End the turn with `LOOP_STATUS: DONE`.
- **Criteria not met, `total_changes_completed < max_changes`** → end the turn with
  `LOOP_STATUS: CONTINUE` (next iteration re-enters `EXPLORE_NEXT`).
- **Criteria not met, `total_changes_completed >= max_changes`** → set `status: paused`, then:

  ```
  PushNotification({
    message: "loop-openspec paused: hit max_changes (<N>) without meeting completion criteria for '<goal_slug>'. Review scope.",
    status: "proactive"
  })
  ```

  End the turn with `LOOP_STATUS: PAUSED`.

## Composing with `/loop`

This skill never calls `ScheduleWakeup` itself — it only runs exactly one iteration per invocation
and ends its turn with one of the three sentinel lines above. To run unattended, the user wraps it in
the built-in `/loop` skill (`/loop /loop-openspec <goal>`), which owns the actual scheduling
decision. Keep the sentinel line as the very last line of the turn so it's unambiguous to find.

**Known open assumption, not yet validated end-to-end:** that `/loop` stops re-firing once it sees
this skill isn't asking to continue. Don't rely on this for a large goal until it's been confirmed
with a small supervised run first (see the skill's design doc,
`docs/superpowers/specs/2026-07-06-loop-openspec-design.md`, Testing plan).

## Out of scope (v1)

- No Codex CLI / Gemini CLI support.
- No OpenSpec bootstrapping — the target project must already have `openspec/` set up.
- No git worktree isolation.
- No multi-goal concurrency.
- No stronger-than-same-model verification.
````

- [ ] **Step 2: Verify the frontmatter is well-formed**

```bash
awk '/^---$/{c++} c==2{exit} {print} c' skills/loop-openspec/SKILL.md | head -5
grep -c '^name: loop-openspec$' skills/loop-openspec/SKILL.md
grep -c '^description:' skills/loop-openspec/SKILL.md
grep -c '^allowed-tools:' skills/loop-openspec/SKILL.md
```

Expected: the first command prints two lines starting with `---` bracketing `name: loop-openspec`
(frontmatter closes properly); each `grep -c` prints `1`.

- [ ] **Step 3: Commit**

```bash
git add skills/loop-openspec/SKILL.md
git commit -m "$(cat <<'EOF'
feat(loop-openspec): add skill definition

Turns a Goal into an unattended OpenSpec loop (explore -> propose/plan
-> apply -> verify -> archive), composing with the built-in /loop
skill for scheduling. See docs/superpowers/specs/2026-07-06-loop-openspec-design.md
for the full design rationale.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Register the skill locally and in repo docs

**Files:**
- Modify: `README.md:38-44` (skill list table)
- Modify: `AGENTS.md:20` (distributed skills "Current members" list)

- [ ] **Step 1: Link the new skill for local dev/testing**

```bash
scripts/link-skills.sh
ls -la .agents/skills/loop-openspec
cat .claude/skills/loop-openspec/SKILL.md | head -3
```

Expected: a new symlink `.agents/skills/loop-openspec -> ../../skills/loop-openspec`, and the `cat`
prints the `---` frontmatter fence (confirms the whole `.claude/skills` chain resolves).

- [ ] **Step 2: Add a row to README.md's skill list table**

In `README.md`, the "Skill list" table currently ends with the `git-commit` row (around line 43). Add
a new row directly after it:

```markdown
| [loop-openspec](skills/loop-openspec/SKILL.md) | Turn a Goal into an unattended OpenSpec loop (explore → propose → apply → verify → archive) | Claude Code only; explicit invocation only (`/loop-openspec <goal>`, or `/loop /loop-openspec <goal>` for unattended runs) |
```

- [ ] **Step 3: Add the skill to AGENTS.md's distributed-skills list**

In `AGENTS.md` line 20, the table row currently reads:

```markdown
| Externally distributed skills | `skills/<name>/` | `npx skills add git@github.com-personal:jason-xie-123/jason-personal-skills.git` | `doc-authority-audit`, `doc-md-title-export`, `english-speaking-practice`, `git-commit` |
```

Change the "Current members" cell to add `loop-openspec`:

```markdown
| Externally distributed skills | `skills/<name>/` | `npx skills add git@github.com-personal:jason-xie-123/jason-personal-skills.git` | `doc-authority-audit`, `doc-md-title-export`, `english-speaking-practice`, `git-commit`, `loop-openspec` |
```

- [ ] **Step 4: Commit**

```bash
git add README.md AGENTS.md
git commit -m "$(cat <<'EOF'
docs: register loop-openspec in README and AGENTS.md

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Build a real OpenSpec sandbox project for testing

**Files:**
- Create (outside this repo, in the scratchpad): a throwaway git project with OpenSpec initialized
  and a tiny real app to exercise APPLY/VERIFY against.

- [ ] **Step 1: Create the sandbox and initialize OpenSpec (default core profile — do not touch global config)**

```bash
mkdir -p /private/tmp/claude-501/-Users-chaoxie-codes-jason-personal-skills/c28f1951-594f-4721-8db4-5e295f5baa12/scratchpad/loop-openspec-sandbox
cd /private/tmp/claude-501/-Users-chaoxie-codes-jason-personal-skills/c28f1951-594f-4721-8db4-5e295f5baa12/scratchpad/loop-openspec-sandbox
git init -q
git config user.email "sandbox@example.com"
git config user.name "Sandbox"
npx --yes @fission-ai/openspec@latest init --tools claude --force
ls .claude/skills
```

Expected `ls` output (5 entries — the default core profile, confirmed by direct testing during
design):
```
openspec-apply-change
openspec-archive-change
openspec-explore
openspec-propose
openspec-sync-specs
```

- [ ] **Step 2: Add a minimal real app with one existing test**

Write `server.js` in the sandbox root:

```javascript
const http = require('node:http');

function handleRequest(req, res) {
  if (req.url === '/ping') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ pong: true }));
    return;
  }
  res.writeHead(404);
  res.end();
}

const server = http.createServer(handleRequest);

module.exports = { server, handleRequest };

if (require.main === module) {
  server.listen(3000, () => console.log('listening on 3000'));
}
```

Write `test.js` in the sandbox root:

```javascript
const test = require('node:test');
const assert = require('node:assert');
const { server } = require('./server');

test('GET /ping returns pong', async () => {
  await new Promise((resolve) => server.listen(0, resolve));
  const { port } = server.address();
  const res = await fetch(`http://localhost:${port}/ping`);
  const body = await res.json();
  assert.deepStrictEqual(body, { pong: true });
  server.close();
});
```

- [ ] **Step 3: Verify the existing test passes, then commit the sandbox baseline**

```bash
node --test test.js
```

Expected: `# pass 1`, `# fail 0`.

```bash
git add -A
git commit -q -m "chore: sandbox baseline (openspec init + ping endpoint)"
git log --oneline
```

Expected: one commit shown.

---

### Task 4: Manual test — kickoff and one full happy-path iteration

**Files:** none in this repo — this is an interactive test run inside the sandbox from Task 3, using
the `loop-openspec` skill linked in Task 2.

- [ ] **Step 1: Kick off a small, one-change goal in the sandbox**

In a Claude Code session with cwd set to the sandbox directory from Task 3, invoke:

```
/loop-openspec 目标：给 server.js 加一个 GET /health 接口，返回 {"status":"ok"}。背景：这是一个用 node:http 写的最小 server，已有一个 /ping 接口和 test.js 里对应的 node:test 测试，新接口要仿照 /ping 的写法，并在 test.js 里补一个对应的测试。完成标准：/health 返回 200 且 body 精确等于 {"status":"ok"}，且 `node --test test.js` 全部通过。
```

- [ ] **Step 2: Verify INIT produced a correct state file**

```bash
cat openspec/loop-engineering/*/state.md
```

Expected: frontmatter with `status: running`, `consecutive_failures: 0`,
`total_changes_completed: 0`, and the Goal/Background/Completion Criteria sections containing the
text from Step 1 verbatim.

- [ ] **Step 3: Let the iteration run to completion, then verify the outcome**

```bash
cat openspec/loop-engineering/*/state.md
git log --oneline
ls openspec/changes/archive/
node --test test.js
```

Expected:
- State file: `status: done` (a one-change goal like this should satisfy its own completion
  criteria after one archived change), `total_changes_completed: 1`, Iteration Log has one row with
  Phase `archived` and Verifier `PASS`.
- `git log --oneline` shows at least 4 new commits since the sandbox baseline: a `docs: propose`, one
  or more `feat(...): implement task N of ...`, and a `chore: archive ...`.
- `openspec/changes/archive/` contains a dated folder for the change.
- `node --test test.js` shows `# pass 2`, `# fail 0` (the original `/ping` test plus the new
  `/health` test).
- The turn's last line was `LOOP_STATUS: DONE`.

If any of these don't hold, that's a bug in `SKILL.md`'s instructions — fix the relevant section in
`skills/loop-openspec/SKILL.md`, re-run this task from Step 1 in a fresh copy of the Task 3 sandbox,
and don't proceed to Task 5 until this passes.

---

### Task 5: Manual test — FIX_RETRY and the 3-failure PAUSED guardrail

**Files:** none in this repo — interactive test in a fresh copy of the Task 3 sandbox.

- [ ] **Step 1: Reset to a fresh sandbox copy and kick off the same goal as Task 4**

```bash
rm -rf /private/tmp/claude-501/-Users-chaoxie-codes-jason-personal-skills/c28f1951-594f-4721-8db4-5e295f5baa12/scratchpad/loop-openspec-sandbox-2
cp -R /private/tmp/claude-501/-Users-chaoxie-codes-jason-personal-skills/c28f1951-594f-4721-8db4-5e295f5baa12/scratchpad/loop-openspec-sandbox /private/tmp/claude-501/-Users-chaoxie-codes-jason-personal-skills/c28f1951-594f-4721-8db4-5e295f5baa12/scratchpad/loop-openspec-sandbox-2
```

In a Claude Code session with cwd set to `loop-openspec-sandbox-2`, run the same kickoff message as
Task 4 Step 1, but stop it after `PROPOSE_PLAN` completes (before APPLY) — interrupt the run there.

- [ ] **Step 2: Deliberately break the change so VERIFY must catch it**

```bash
cd /private/tmp/claude-501/-Users-chaoxie-codes-jason-personal-skills/c28f1951-594f-4721-8db4-5e295f5baa12/scratchpad/loop-openspec-sandbox-2
find openspec/changes -name tasks.md
```

Open the `tasks.md` found and manually check off (`- [x]`) every task in it, without actually writing
any `/health` code — this simulates APPLY claiming completion it didn't earn.

```bash
git add -A && git commit -q -m "test: fake-complete tasks.md without implementing (induced-failure fixture)"
```

- [ ] **Step 3: Run the VERIFY step in isolation and confirm it catches the fake completion**

Invoke `loop-openspec`'s VERIFY step manually (spawn the fresh `Agent` with the exact prompt from
`skills/loop-openspec/SKILL.md`'s VERIFY section, filling in the real change name from
`openspec/changes/`).

Expected: the subagent's report includes at least one CRITICAL issue (task checked off but `/health`
doesn't exist in `server.js`), and its last line is `VERDICT: FAIL`.

- [ ] **Step 4: Confirm the FIX_RETRY → PAUSED guardrail fires after 3 such failures**

Repeat: leave `tasks.md` fake-completed (don't fix it), re-run VERIFY two more times (3 total FAILs).
After the 3rd, check:

```bash
cat openspec/loop-engineering/*/state.md
```

Expected: `consecutive_failures: 3`, `status: paused`, Iteration Log's last row shows
`fix_retry (3/3)` / `FAIL`, and a `PushNotification` fired with a message matching
`loop-openspec paused: <change-name> failed verification 3x — ...`. The turn's last line was
`LOOP_STATUS: PAUSED`.

If the guardrail doesn't trip at exactly 3, or trips at the wrong count, fix the FIX_RETRY section of
`skills/loop-openspec/SKILL.md` and re-run this task.

---

### Task 6: Manual test — `max_changes` scope-creep guardrail

**Files:** none in this repo — interactive test in a fresh copy of the Task 3 sandbox.

- [ ] **Step 1: Fresh sandbox, kick off a goal that can't be satisfied by one change**

```bash
rm -rf /private/tmp/claude-501/-Users-chaoxie-codes-jason-personal-skills/c28f1951-594f-4721-8db4-5e295f5baa12/scratchpad/loop-openspec-sandbox-3
cp -R /private/tmp/claude-501/-Users-chaoxie-codes-jason-personal-skills/c28f1951-594f-4721-8db4-5e295f5baa12/scratchpad/loop-openspec-sandbox /private/tmp/claude-501/-Users-chaoxie-codes-jason-personal-skills/c28f1951-594f-4721-8db4-5e295f5baa12/scratchpad/loop-openspec-sandbox-3
```

In a Claude Code session with cwd set to `loop-openspec-sandbox-3`, kick off:

```
/loop-openspec 目标：给 server.js 依次加 3 个新接口：/health、/version、/ready，每个都要仿照 /ping 的写法并在 test.js 补对应测试。背景：一次只做一个接口，每个接口都单独走一次 OpenSpec change。完成标准：/health、/version、/ready 三个接口都存在且测试通过。
```

- [ ] **Step 2: After kickoff, manually cap `max_changes` low so the guardrail is reachable quickly**

```bash
cd /private/tmp/claude-501/-Users-chaoxie-codes-jason-personal-skills/c28f1951-594f-4721-8db4-5e295f5baa12/scratchpad/loop-openspec-sandbox-3
sed -i '' 's/^max_changes:.*/max_changes: 1/' openspec/loop-engineering/*/state.md
cat openspec/loop-engineering/*/state.md | head -6
```

Expected: `max_changes: 1` now shown in the frontmatter.

- [ ] **Step 3: Let one full iteration run (one change archived) and confirm the guardrail pauses the run**

Since the goal needs 3 changes but `max_changes` is capped at 1, after the first change archives,
`CHECK_GOAL_DONE` should find `total_changes_completed (1) >= max_changes (1)` while completion
criteria (all 3 endpoints) are still unmet.

```bash
cat openspec/loop-engineering/*/state.md
```

Expected: `status: paused`, `total_changes_completed: 1`, and a `PushNotification` fired matching
`loop-openspec paused: hit max_changes (1) without meeting completion criteria for '<goal_slug>'.
Review scope.`. Turn's last line was `LOOP_STATUS: PAUSED`.

If it instead reports `DONE` or keeps going past the cap, fix the CHECK_GOAL_DONE section of
`skills/loop-openspec/SKILL.md` and re-run this task.

---

### Task 7: Manual test — composing with `/loop` for an unattended run

**Files:**
- Modify: `docs/superpowers/specs/2026-07-06-loop-openspec-design.md` (record the outcome of the
  open assumption)

- [ ] **Step 1: Fresh sandbox, kick off the same one-change goal as Task 4 wrapped in `/loop`**

```bash
rm -rf /private/tmp/claude-501/-Users-chaoxie-codes-jason-personal-skills/c28f1951-594f-4721-8db4-5e295f5baa12/scratchpad/loop-openspec-sandbox-4
cp -R /private/tmp/claude-501/-Users-chaoxie-codes-jason-personal-skills/c28f1951-594f-4721-8db4-5e295f5baa12/scratchpad/loop-openspec-sandbox /private/tmp/claude-501/-Users-chaoxie-codes-jason-personal-skills/c28f1951-594f-4721-8db4-5e295f5baa12/scratchpad/loop-openspec-sandbox-4
```

In a Claude Code session with cwd set to `loop-openspec-sandbox-4`, invoke:

```
/loop /loop-openspec 目标：给 server.js 加一个 GET /health 接口，返回 {"status":"ok"}。背景：这是一个用 node:http 写的最小 server，已有一个 /ping 接口和 test.js 里对应的 node:test 测试，新接口要仿照 /ping 的写法，并在 test.js 里补一个对应的测试。完成标准：/health 返回 200 且 body 精确等于 {"status":"ok"}，且 `node --test test.js` 全部通过。
```

Stay and observe rather than walking away, since this is the supervised validation run.

- [ ] **Step 2: Watch whether `/loop` schedules a next firing after `loop-openspec` reports DONE**

Since the goal only needs one change, `loop-openspec` should reach `LOOP_STATUS: DONE` after its
first iteration completes. Observe whether `/loop` schedules another wake-up anyway (which would
mean the "stops when not asked to continue" assumption is wrong) or correctly stops.

- [ ] **Step 3: Record the outcome in the design doc**

Open `docs/superpowers/specs/2026-07-06-loop-openspec-design.md`, find the "Composing with `/loop`"
section's "Open assumption to validate" paragraph, and replace it with the confirmed result — either:

```markdown
**Validated 2026-07-06:** `/loop` does stop re-firing once `loop-openspec` reports `LOOP_STATUS: DONE`
and doesn't request continuation. Confirmed with a supervised one-iteration run in a sandbox project.
```

or, if it did NOT stop correctly, write what actually happened and what follow-up is needed instead
(e.g. `loop-openspec` may need to call something explicit rather than relying on absence-of-request).
Do not guess — write exactly what you observed.

- [ ] **Step 4: Commit the design doc update**

```bash
git add docs/superpowers/specs/2026-07-06-loop-openspec-design.md
git commit -m "$(cat <<'EOF'
docs: record loop-openspec + /loop validation result

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review notes

- **Spec coverage:** every design-doc section (Scope, Invocation, State file, State machine,
  Guardrails, Commit strategy, Composing with `/loop`, Out of scope, Testing plan) has a
  corresponding task or is embedded verbatim in the Task 1 file content.
- **No placeholders:** all bash commands, file paths, and prompt templates are given in full; the
  only bracketed tokens (`<change-name>`, `<goal-slug>`, `<N>`) are documented template variables,
  matching this repo's existing convention in `skills/git-commit/SKILL.md`.
- **Consistency check:** state names (`INIT`, `EXPLORE_NEXT`, `PROPOSE_PLAN`, `APPLY`, `VERIFY`,
  `ARCHIVE`, `FIX_RETRY`, `CHECK_GOAL_DONE`, `DONE`/`CONTINUE`/`PAUSED`) match exactly between the
  design doc and the `SKILL.md` content in Task 1, and the sentinel line format (`LOOP_STATUS: ...`)
  is used identically in every task that checks for it (Tasks 4, 5, 6, 7).
