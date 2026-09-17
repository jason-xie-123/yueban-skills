# loop-openspec skill design

## Purpose

A skill that turns a single, possibly large, `Goal` into an unattended loop: repeatedly derive the next
most valuable OpenSpec change, propose/plan/implement it, verify it independently, archive it, and
decide whether the overall goal is done — without the user re-explaining context on every round.

## Scope & assumptions

- **Claude Code only.** The unattended mode composes with the built-in `/loop` skill (self-paced
  `ScheduleWakeup`) and spawns an independent verifier via the `Agent` tool, and uses `PushNotification`
  for completion/stuck alerts. None of these have guaranteed equivalents in Codex CLI / Gemini CLI, so
  this skill does not attempt cross-client support (unlike the rest of this repo's skills).
- **OpenSpec must already be set up in the target project on its default ("core") profile**
  (`openspec init` run, `openspec/` directory present, `.claude/skills/openspec-explore`,
  `openspec-propose`, `openspec-apply-change`, `openspec-archive-change`, `openspec-sync-specs` all
  installed). Confirmed by direct inspection of a real `openspec init --tools claude` run — the core
  profile already includes `propose`, `explore`, `apply`, `sync`, `archive`; only `verify` is excluded
  from core (it requires switching global config to `profile: custom` with `verify` in `workflows`).
  **`loop-openspec` deliberately does not require that global switch** (see VERIFY below), so plain
  default `openspec init` is sufficient. If `openspec/` isn't found, the skill tells the user to run
  `openspec init` first and stops — it does not bootstrap OpenSpec itself.
- **Claude Code integration is Skill-based, not slash-commands.** OpenSpec installs real
  `SKILL.md`-based skills under `.claude/skills/openspec-*`, triggered by natural-language description
  match (or an explicit `Skill` tool call by name) — there is no `/opsx:foo` slash command for Claude
  Code specifically (that naming applies to a different delivery mode/tool, not what actually gets
  installed here — verified by running a real `init` and inspecting the generated files).
- Runs directly in the user's current working directory — **no git worktree isolation**. This assumes
  the user won't be hand-editing the same project while an unattended run is in progress.
- One active goal/state file per invocation. No multi-goal concurrency handling in v1.

## Invocation

Explicit trigger only (never auto-triggered — it writes code and can run unattended):

```
# Kickoff, unattended (wraps in the built-in /loop skill for self-paced scheduling):
/loop /loop-openspec 目标：<one-line goal>。背景：<constraints, current-state context, desired
technical direction — everything the implementer needs, said once>。完成标准：<how to know the
whole goal is truly done — this is what CHECK_GOAL_DONE checks against>

# Kickoff, manual step-by-step (you re-invoke each round yourself):
/loop-openspec 目标：<...>。背景：<...>。完成标准：<...>

# Resume (reads everything back out of the state file, no re-explaining):
/loop-openspec continue
/loop-openspec                      # bare call = same as continue

# Append new context mid-run without restarting:
/loop-openspec <new context to append to the state file>
```

## Composing with `/loop`

`loop-openspec` does not call `ScheduleWakeup` itself. It only defines what one iteration does and
leaves an unambiguous status behind (state file `status:` field + final turn text: `DONE` / `PAUSED` /
`CONTINUE`). The wrapping `/loop` skill's own self-pacing logic decides whether to schedule the next
firing. This keeps the two skills single-responsibility instead of reimplementing scheduling.

**Validated 2026-07-06.** A live test in the main session invoked the built-in `/loop` skill directly
(dynamic/self-paced mode, no interval) with a trivial, unrelated, explicitly-one-shot-complete prompt,
and read `/loop`'s own authoritative instructions rather than guessing at its behavior. Its documented
"stop the loop" step (dynamic mode, step 6) says exactly: *"omit the ScheduleWakeup call"* — i.e. `/loop`
does not re-fire unless the wrapped work explicitly schedules the next wake-up itself. Since
`loop-openspec` never calls `ScheduleWakeup` and only leaves a `LOOP_STATUS: DONE/PAUSED/CONTINUE`
sentinel, the composition is sound: `/loop` naturally stops on `DONE`/`PAUSED` (nothing schedules a
next firing) and only continues past `CONTINUE` if whoever is driving the loop calls `ScheduleWakeup`
again with the `/loop-openspec` continuation prompt, per `/loop`'s own dynamic-mode contract. This
could not be tested by dispatching a subagent — both `ScheduleWakeup` and `PushNotification` are
unavailable to dispatched subagents, confirmed separately during Tasks 4-6 — so the validation was
done directly in the main session instead, with no lasting side effects (no wake-up was scheduled).

## State file

Location: `openspec/loop-engineering/<goal-slug>/state.md` — lives beside `openspec/changes/` in the
target project (travels with the project, not with this skills repo).

```markdown
---
goal_slug: add-rate-limiting
status: running        # running | done | paused
consecutive_failures: 0
total_changes_completed: 0
max_changes: 20         # total-count guardrail; override at kickoff if needed
---

# Goal
<verbatim goal text from kickoff>

# Background / Constraints
<verbatim background text from kickoff>

# Completion Criteria
<verbatim completion criteria from kickoff — CHECK_GOAL_DONE judges against this>

# Appended Context
<content from any follow-up `/loop-openspec <new context>` calls, appended in order, never overwritten>

# Iteration Log
| # | Change | Phase | Verifier | Notes |
|---|---|---|---|---|
| 1 | add-token-bucket | archived | PASS | |
| 2 | add-rate-limit-middleware | fix_retry (2/3) | FAIL | missing concurrent-request edge case |

# Carry-forward notes from last EXPLORE
<short notes for next round's dynamic next-step derivation, so it isn't starting from zero each time>
```

This file is the single source of truth across turns — the skill must never rely on anything from
earlier in the conversation that isn't persisted here, since long unattended runs may get compacted.

## Per-iteration state machine

`INIT → EXPLORE_NEXT → PROPOSE_PLAN → APPLY → VERIFY → (ARCHIVE | FIX_RETRY) → CHECK_GOAL_DONE →
(DONE | CONTINUE | PAUSED)`

- **INIT**: no state file yet → write goal/background/completion-criteria verbatim, go to `EXPLORE_NEXT`.
- **EXPLORE_NEXT**: invoke the `openspec-explore` skill (natural-language trigger: "explore what the
  next most valuable change toward `<goal>` would be, given `<iteration log + carry-forward notes>`")
  against the repo's current state + the state file to pick a single next change. Derived dynamically
  each round — no fixed upfront roadmap.
- **PROPOSE_PLAN**: invoke the `openspec-propose` skill for the chosen change, review the generated
  proposal/specs/design/tasks (OpenSpec's `propose` step produces all of these in one pass — there is
  no separate later "plan" step). Commit (see below) once the spec artifacts are settled.
- **APPLY**: invoke the `openspec-apply-change` skill, implementing tasks directly in the current
  working directory (the "maker"). Commit after each completed task (or small group of related tasks),
  not only at the end.
- **VERIFY**: `loop-openspec` does **not** depend on OpenSpec's own `openspec-verify-change` skill,
  because that skill only exists if the target project's *global* OpenSpec config has been switched to
  `profile: custom` with `verify` added to `workflows` — a machine-wide setting this skill should not
  require the user to flip just to use `loop-openspec` (confirmed by direct testing: `core`, the
  default profile, does not include `verify`). Instead, `loop-openspec` carries its own self-contained
  verification instructions, replicating the same three dimensions OpenSpec's own verify workflow
  checks (completeness against `tasks.md`, correctness against `design.md`/specs, coherence of the
  actual code), issue-graded CRITICAL / WARNING / SUGGESTION. Spawn one fresh, independent `Agent`
  (general-purpose, not a fork — must not share the maker's context) with that verification prompt,
  telling it to read the change's `proposal.md`/specs/`design.md`/`tasks.md`, read the `git diff` for
  this change, run the project's tests/build if present, and return its issue list. `loop-openspec`
  maps that report to its own gate: **PASS** iff zero CRITICAL issues; **FAIL** if any CRITICAL issue
  (WARNING/SUGGESTION are logged in the iteration log but don't block).
  - **Caveat to keep in the skill's own documentation**: this verifier is the same underlying model in
    a fresh context, not an independently-trained checker. It reliably catches missed tasks and
    obvious test/build failures; it does **not** reliably catch a misunderstanding the maker and
    verifier both happen to share. Treat it as a real but partial safety net, not a strong guarantee.
- **ARCHIVE** (on PASS): run the plain CLI directly — `openspec archive <change-name> --yes --json` —
  rather than going through an AI skill, since archiving is a mechanical operation (move the folder,
  sync specs) once our own VERIFY gate has already passed; this is more reliable than depending on the
  agent correctly triggering an AI skill for a step that doesn't need AI judgment. The command moves
  the change folder to `openspec/changes/archive/YYYY-MM-DD-<name>/` and updates main specs in the same
  step (add `--skip-specs` only for doc/infra-only changes with no spec deltas). Note OpenSpec's own
  archive step only *warns* on incomplete tasks, it doesn't block — `loop-openspec` must not call
  archive at all unless its own VERIFY gate above already passed. After archiving: commit the archive
  move, reset the failure counter, append to the iteration log, go to `CHECK_GOAL_DONE`.
- **FIX_RETRY** (on FAIL): increment `consecutive_failures` for this change.
  - `< 3`: revise the implementation using the verifier's feedback, commit the fix, go back to `VERIFY`.
  - `== 3`: → `PAUSED`.
- **CHECK_GOAL_DONE**: check the goal's completion criteria against everything archived so far.
  - Criteria met → `DONE`.
  - Criteria not met, `total_changes_completed < max_changes` → `CONTINUE` (next iteration re-enters
    `EXPLORE_NEXT`).
  - Criteria not met, `total_changes_completed >= max_changes` → `PAUSED` (scope-creep guardrail).

## Guardrails & notifications

- **Consecutive-failure guardrail**: 3 failed verifications on the same change → `PAUSED`,
  `PushNotification` explaining what's stuck and why, stop scheduling further work.
- **Total-count guardrail**: `total_changes_completed` reaches `max_changes` (default 20, overridable
  at kickoff) without satisfying completion criteria → `PAUSED`, `PushNotification` noting the goal may
  have grown beyond its original scope during dynamic derivation — come back and review the roadmap.
- **Completion**: criteria satisfied → `DONE`, `PushNotification` summarizing what was completed, stop.
- Otherwise (`CONTINUE`): end the turn normally; if running under `/loop`, that skill brings it back.

## Commit / push strategy

Every checkpoint commits and pushes directly via plain `git` (`git add -A && git commit -m "..." &&
git push || git push -u origin HEAD`) — no dependency on any other skill (such as this repo's own
`git-commit`) being installed in the target project. Suited to a personal/dedicated branch or repo,
not a shared branch with teammates who'd be surprised by frequent intermediate pushes:

| Checkpoint | Example commit |
|---|---|
| PROPOSE_PLAN spec artifacts settled | `docs: propose <change-name>` |
| Each completed task (or small related group) during APPLY | `feat(<scope>): implement task N of <change-name>` |
| Each FIX_RETRY round | `fix(<scope>): address verifier feedback on <change-name>` |
| ARCHIVE completes | `chore: archive <change-name>` |

This keeps even a paused/blocked run reviewable as a sequence of small, revertible commits instead of
one large undifferentiated diff.

## Out of scope for v1

- No Codex CLI / Gemini CLI support.
- No OpenSpec bootstrapping/initialization.
- No git worktree isolation.
- No multi-goal concurrency (parallel active state files).
- No dependency on (or requirement to enable) OpenSpec's global `custom` profile / `verify` workflow —
  `loop-openspec` brings its own verification prompt instead, precisely so it works against any project
  that has plain default `openspec init` and nothing more.
- No stronger-than-same-model verification (e.g. a genuinely different model or human-in-the-loop
  review gate) — noted as a known limitation, not solved here.

## Testing / validation plan

0. Set up a throwaway sandbox project: `npx @fission-ai/openspec@latest init --tools claude` (default
   core profile — do not touch global config). Confirm `.claude/skills/openspec-{explore,propose,
   apply-change,archive-change,sync-specs}` exist. Do not test against a real project first. **Done**
   — see `docs/superpowers/plans/2026-07-06-loop-openspec.md` Task 3.
1. Manually invoke `loop-openspec` step-by-step (not wrapped in `/loop`) on a small real goal in that
   sandbox project, to validate the state machine transitions and the state file format. **Done** —
   Task 4: succeeded end-to-end, `LOOP_STATUS: DONE`, correct state file/commits/tests.
2. Deliberately induce a verifier FAIL to confirm the `FIX_RETRY` → `PAUSED` guardrail and
   `PushNotification` fire correctly at 3 consecutive failures. **Done** — Task 5: guardrail tripped at
   exactly 3, not 2 or 4; `PushNotification` unavailable in the test context, correctly fell back to
   printing the message per the skill's own documented fallback.
3. ~~Wrap in `/loop /loop-openspec ...` for one supervised unattended run on a small goal, watching to
   confirm `/loop` stops re-firing once `loop-openspec` reports `DONE`.~~ **Superseded** — this
   couldn't be done as originally planned (dispatched subagents don't have `ScheduleWakeup` access, so
   they can't exercise `/loop`'s real scheduling behavior). Instead, validated directly in the main
   session by invoking `/loop` itself (dynamic mode) with a trivial, unrelated, one-shot-complete
   prompt and reading its own authoritative instructions — confirmed the assumption exactly (see
   "Composing with `/loop`" above). No live wrapped run of `loop-openspec` under `/loop` has been done;
   that first real run should still be supervised, per point 4 below.
4. Before trusting this on a large, genuinely multi-change goal: run it wrapped in `/loop` for the
   first time on a small goal, supervised, to confirm the two mechanisms compose correctly together in
   practice (each has now been validated separately, but not yet together in one live run).
