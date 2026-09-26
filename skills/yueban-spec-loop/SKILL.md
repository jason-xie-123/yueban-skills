---
name: yueban-spec-loop
description: '把一个 Goal 变成一个无人值守、自驱动的 OpenSpec 循环：动态挑选下一个价值最高的 change，进行 propose/plan，实现它，用一个全新的独立 agent 对照 spec 验证并做代码 review，归档它，并判断整个 goal 是否完成——如此重复，直到 DONE 或某个护栏暂停它以供人工审阅。仅限 Claude Code：与内置的 /loop 技能（用于调度）以及 PushNotification（用于提醒）组合使用。只在明确调用时使用——用 "/yueban-spec-loop <目标...>" 启动，用 "/yueban-spec-loop continue" 或裸的 "/yueban-spec-loop" 恢复，用 "/loop /yueban-spec-loop <目标...>" 进行完全无人值守的运行。要求目标项目已经初始化过 OpenSpec（openspec init，默认的 core profile 就够）——本技能不负责为项目引导安装 OpenSpec 本身。**注意：本技能会自动 push 到 origin，无需确认（与本仓库另外两个 spec 流程 skill——yueban-spec-single-change-flow、yueban-spec-roadmap-flow——"只 commit 不 push"的约定不同），因为它是设计给完全无人值守运行的；实现代码经过一次 VERIFY（spec 对照 + 代码 review）和一次修复后，不管是否仍有问题都随归档一起 push——review 从不让循环停下，遗留问题写进 archive 的 commit message 和 Iteration Log 供人事后审阅。不想自动 push 到远端就不要用它。**'
allowed-tools: Bash, Read, Write, Edit, Skill, Agent, PushNotification
---

# Loop OpenSpec

## 概述

把一个大的 `Goal` 转化为在 OpenSpec changes 之上自驱动的循环：EXPLORE_NEXT → PROPOSE_PLAN →
APPLY → VERIFY →（FAIL 时 FIX 一次）→ ARCHIVE → CHECK_GOAL_DONE，如此重复，直到满足 goal 的完成
标准，或某个护栏暂停运行等你查看。用户在启动时一次性说明目标、背景和完成标准；之后每次调用
都从状态文件中读回这些信息，而不需要你重新解释任何内容。

## 适用范围与前提条件

- **仅限 Claude Code。** 无人值守模式与内置的 `/loop` 技能（自主节奏的
  `ScheduleWakeup`）组合使用；独立验证器使用 `Agent` 工具；护栏使用
  `PushNotification`。这些在 Codex CLI / Gemini CLI 中都没有确定的等价物。
- **必须在项目根目录就是目标项目本身的会话中调用**——而不是通过一个项目根目录指向别处的
  已派发子代理。技能发现（针对
  `openspec-explore`/`openspec-propose`/`openspec-apply-change`）绑定的是会话实际的
  项目根目录，而不仅仅是工作目录。
- **在每个检查点直接通过 `git` 提交，并在两个时机自动推送**（add/commit/push，push 到 origin 不需要额外确认）：
  `PROPOSE_PLAN` 的 spec 文档提交立即推送；`APPLY`/`FIX` 的实现提交先留在本地，`ARCHIVE` 提交之后一起推送。
  **代码 review 从不让循环停下**：`VERIFY` 只跑一次、`FIX` 只修一次，然后不管是否仍有问题都归档并推送，
  遗留问题写进 archive 的 commit message（标题带 ` [known gaps]`）和 Iteration Log——本技能的目的是
  让人不用守在执行过程里，review 的结果留给人事后看。
  本技能不依赖目标项目安装了其他任何技能（比如本仓库自带的 `yueban-git-commit`）。这是本技能区别于 `yueban-spec-single-change-flow`/`yueban-spec-roadmap-flow`（两者都只 commit、不自动 push）的关键差异：本技能是为完全无人值守运行设计的，没人在场按 `yueban-git-commit` 的"push 前确认"逻辑做确认，所以 push 是自动的、无提示的。
- **目标项目必须已经在其默认 profile 下初始化过 OpenSpec。** 做任何事之前先检查：

  ```bash
  command -v openspec >/dev/null || { echo "openspec CLI not on PATH. Install it (see openspec docs), then re-invoke this skill."; exit 1; }
  test -d openspec || { echo "OpenSpec not found. Run: openspec init --tools claude (or npx @fission-ai/openspec@latest init --tools claude), then re-invoke this skill."; exit 1; }
  for s in openspec-explore openspec-propose openspec-apply-change; do
    test -d ".claude/skills/$s" || { echo "Missing .claude/skills/$s — re-run: openspec update --force"; exit 1; }
  done
  ```

  如果任一检查失败，明确告诉用户该运行什么命令，然后停止。不要代替用户去执行
  `openspec init`。
- **没有 git worktree 隔离**——直接在当前工作目录中运行。无人值守运行进行期间，不要手动
  编辑同一个项目。
- **同一项目同一时间只能有一个活跃的 goal。** 本技能不支持并发运行两个 goal。

## 调用方式

```
# 启动，无人值守（包在内置的 /loop 技能里，自动调度）：
/loop /yueban-spec-loop 目标：<一句话目标>。背景：<约束、现状、期望方向——一次性交代完>。完成标准：<怎么算彻底做完了>

# 启动，手动逐轮进行（每一轮由你自己重新调用）：
/yueban-spec-loop 目标：<...>。背景：<...>。完成标准：<...>

# 恢复——从状态文件中读回一切信息，无需重新解释：
/yueban-spec-loop continue
/yueban-spec-loop

# 在不重启当前运行的情况下，向其追加新背景：
/yueban-spec-loop <要追加的新背景或说明>
```

## 步骤 1 —— 查找或创建状态文件

```bash
ls openspec/loop-engineering/*/state.md 2>/dev/null
```

对用户消息分类：如果包含 目标/背景/完成标准（新的目标文本），归为**启动**；否则归为
**continue/append**（裸的 `/yueban-spec-loop`、`/yueban-spec-loop continue`，或任意补充背景）。
这是一个启发式判断，不是字面字符串匹配——消息含糊时用你自己的判断。

- **启动，且本项目中另一个 `state.md` 已经是 `status: running` 或 `status: paused`，对应
  **另一个**目标**：本项目已经有一个活跃的 goal（本技能只支持同一项目同时有一个活跃 goal——见
  "适用范围与前提条件"）。告诉用户那个 goal 的 `goal_slug` 和当前状态，问他们是否想继续那个，
  而不是启动第二个。以 `LOOP_STATUS: PAUSED` 结束本轮并等待。如果他们确认要继续现有 goal，
  按下面匹配的 `running`/`paused` continue 情况处理；如果他们坚持要一个真正的新 goal，
  这超出了本技能的范围（见"适用范围与前提条件"）——告诉他们这一点，而不是创建第二个并发的
  状态文件。
- **启动，且该 goal 尚不存在对应的 `state.md`，且没有其他 goal 处于活跃状态**：无论目标是用
  什么语言给出的，都要推导出一个简短（3-6 词）的 kebab-case 英文 slug 来概括目标（例如一个
  关于限流的中文目标 → `add-rate-limiting`）。用下方"状态文件格式"中的模板创建
  `openspec/loop-engineering/<slug>/state.md`，逐字填入 Goal / Background / Completion Criteria。
  转到 `EXPLORE_NEXT`。
- **启动，且已经存在同一 slug 的 `state.md`**：
  - 如果其 `status` 是 `running` 或 `paused`：把新文本追加到该文件的 `# Appended Context`
    部分（不要覆盖 Goal/Background/Completion Criteria），然后按下面 continue 的方式处理。
  - 如果其 `status` 是 `done`：这个 goal 已经完成过了。告诉用户该 slug、完成时间（从其
    Iteration Log 中总结），并询问他们是想 (a) 用一个不同的 slug 为一个相关但不同的目标
    开启一个真正的新运行，还是 (b) 他们弄错了、其实想说别的事情。不要静默覆盖或重新打开一个
    `done` 状态文件。以 `LOOP_STATUS: PAUSED` 结束本轮，等待回答。
- **Continue/append，且恰好一个 `state.md` 是 `status: running`**：如果消息中有额外背景，
  追加到 `# Appended Context`；从 Iteration Log 最后停下的地方继续。
- **Continue/append，且恰好一个 `state.md` 是 `status: paused`**：告诉用户暂停的原因（从
  Iteration Log 最后一行读取，或从 `total_changes_completed >= max_changes` 这个事实推断；暂停只会来自
  EXPLORE_NEXT 找不到下一个 change、PROPOSE_PLAN 产物异常、APPLY 被 guardrail 阻塞、`max_changes`
  这几个护栏，不会来自代码 review），
  并询问他们想如何处理。如果这条消息里用户还没有给出回答，就以 `LOOP_STATUS: PAUSED` 结束
  本轮并等待——一旦他们回复：
  - **旧版本留下的状态**（frontmatter 里有 `consecutive_failures`，或者 Iteration Log 最后一行是
    `fix_retry (3/3)`——旧版"连续 3 次 VERIFY 失败"护栏的暂停）：不用等用户表态，这个护栏已经取消。
    删掉 `consecutive_failures` 字段，补上 `changes_with_known_gaps: 0`（没有的话），设置
    `status: running`，按新规则处理卡住的 change：它已经被修过多次，不再 `FIX`，直接用 Iteration Log
    里最后一次验证器的 CRITICAL 作为已知缺口进入 `ARCHIVE`。
  - 如果是被 EXPLORE_NEXT / PROPOSE_PLAN / APPLY 护栏暂停的：按用户的答复调整后设置
    `status: running`，从暂停的那一步继续（进行中的 change 通过 `ls openspec/changes/`（排除
    `archive/`）找到——尚未归档的那个就是）。
  - 如果是被 `max_changes` 护栏暂停的：如果用户给出新的上限，更新 frontmatter 中的
    `max_changes`，设置 `status: running`，转到 `EXPLORE_NEXT`。如果他们表示 goal 就这样
    算完成了，设置 `status: done` 并停止（不需要重新进入状态机）。
  - 不要在用户没有表态的情况下静默恢复一个暂停的运行——这正是护栏存在的全部意义。
- **Continue/append，且没有任何 `state.md` 是 `status: running` 或 `status: paused`**：
  告诉用户本项目中没有活跃的 `yueban-spec-loop` 运行，以 `LOOP_STATUS: PAUSED` 结束本轮
  （无事可做——见"与 `/loop` 组合"），然后停止。
- **Continue/append，且有多个 `state.md` 是 `status: running` 或 `status: paused`**：列出它们的
  `goal_slug` 和状态，询问用户指的是哪一个，以 `LOOP_STATUS: PAUSED` 结束本轮，停止直到他们
  回答。

## 状态文件格式

位置：`openspec/loop-engineering/<goal-slug>/state.md`。

```markdown
---
goal_slug: add-rate-limiting
status: running        # running | done | paused
total_changes_completed: 0
changes_with_known_gaps: 0   # ARCHIVE 时带着已知缺口归档的 change 数
max_changes: 20         # 如果用户在启动时要求了不同上限，在此覆盖
---

# Goal
<逐字>

# Background / Constraints
<逐字>

# Completion Criteria
<逐字>

# Appended Context
<后续调用追加的任何内容，按顺序排列，从不覆盖>

# Iteration Log
| # | Change | Phase | Verifier | Notes |
|---|---|---|---|---|

# Carry-forward notes from last EXPLORE
<给下一次 EXPLORE_NEXT 步骤的简短笔记>

# Known gaps
<ARCHIVE 时追加的已知缺口，一条一行：`- [<change-name>] <缺口>`；只追加，从不被 EXPLORE_NEXT 覆盖。
后续某个 change 修掉了某条，就把那一行改成 `- ~~[<change-name>] <缺口>~~ fixed by <修掉它的 change-name>`，不删除>
```

## 步骤 2 —— 运行状态机的一轮迭代

`EXPLORE_NEXT → PROPOSE_PLAN → APPLY → VERIFY → (FIX，仅 FAIL 时，一次) → ARCHIVE → CHECK_GOAL_DONE`

### EXPLORE_NEXT

调用 `openspec-explore` 技能（`Skill({skill: "openspec-explore"})`），按以下方式构建问题：
基于状态文件中的 Goal、Completion Criteria、Iteration Log、Carry-forward notes、`# Known gaps`
里还没划掉的条目，以及仓库当前状态，下一个价值最高的 OpenSpec change 是什么？已知缺口（尤其是
构建/测试没通过、没修的 CRITICAL）是正当的候选 change——这是它们在无人值守运行中被修掉的途径。没有固定的预先路线图——每次迭代都要重新推导。
从这一步得出一个简短的 change 名称和 2-4 句理由。

`openspec-explore` 通常是与人类的对话式来回。在无人值守运行时（没有人在场回答追问），不要
等待回复——直接从探索结果中综合出你自己具体的决定，选定一个 change 名称；如果有多个候选
看起来都合理，用 Goal/Completion Criteria/Iteration Log 作为决胜依据。

**探索不出任何候选 change，但 Completion Criteria 显然还没满足**（比如探索结果认为"目标已经
无法再拆出新的 change"，但完成标准写的东西代码里还没有）：这不是 `CHECK_GOAL_DONE` 该判定
"done"的场景（"done"要求标准真的已满足），也不能假装找到一个凑数的 change 硬做下去。把
`status` 设为 `paused`，在 Iteration Log 追加一行说明"探索未能给出下一个 change"及具体原因，
发 `PushNotification`（消息类似 `spec-loop paused: EXPLORE_NEXT found no viable next
change for '<goal_slug>' but completion criteria aren't met yet. Needs scope/goal review.`），
以 `LOOP_STATUS: PAUSED` 结束本轮——这种情况通常意味着 goal 描述本身需要用户重新拆解或收窄，
不是循环能自己解决的。

在进入 `PROPOSE_PLAN` 之前，用 2-4 句话覆写状态文件中的 `# Carry-forward notes from last EXPLORE`
部分：你即将做什么、为什么；在仓库中注意到的、与本次相关但超出本次范围的任何情况；以及任何
值得留给下一轮迭代（或运行后来暂停时留给人类）的未决问题。这样下一次 `EXPLORE_NEXT` 就不用
从零开始。

### PROPOSE_PLAN

针对该 change 名称，调用 `openspec-propose` 技能（`Skill({skill: "openspec-propose"})`）。
检查生成的 `proposal.md` / spec deltas / `design.md` / `tasks.md`，它们位于
`openspec/changes/<change-name>/` 下。OpenSpec 的 propose 步骤一次性生成全部四项——之后没有
单独的"plan"步骤。

**提交：** 一旦 spec 产物看起来没问题，直接提交并推送（本技能不依赖目标项目安装其他任何
技能，比如本仓库自带的 `yueban-git-commit`）：

```bash
git add -A
git commit -m "docs: propose <change-name>"
git push || git push -u origin HEAD
```

**产物看起来不对时**（`openspec-propose` 报错退出、四项产物缺了一项、或读完之后发现内容明显
不成立——比如 `tasks.md` 是空的、`proposal.md` 和这一轮 `EXPLORE_NEXT` 选定的 change 主题对不
上）：**不要**尝试自己动手把它改成"看起来对"再提交，也不要跳过这个 change 直接回到
`EXPLORE_NEXT` 去找下一个——这两种做法都会让 Iteration Log 和实际状态对不上。按 `EXPLORE_NEXT`
"探索未能给出下一个 change"那一段同样的处理方式：把 `status` 设为 `paused`，在 Iteration Log
追加一行说明"PROPOSE_PLAN 产物异常"及具体原因，发 `PushNotification`（消息类似
`spec-loop paused: PROPOSE_PLAN for '<change-name>' produced no usable artifacts —
<one-line reason>. Needs your review.`；无 `PushNotification` 时改为在本轮输出中醒目打印），
以哨兵行 `LOOP_STATUS: PAUSED` 结束本轮。不要提交，也不要继续循环。

### APPLY

针对 `<change-name>` 调用 `openspec-apply-change` 技能
（`Skill({skill: "openspec-apply-change"})`），它会在一次调用里逐一处理完 `tasks.md` 中所有未勾选的任务，处理期间不会把控制权交还给你——也就是说，你没有机会在它执行的过程中、单个任务与任务之间插入提交。

**`openspec-apply-change` 自己按它的 Guardrails 停下来问用户，而不是完成或报错退出时**（它是
目标项目安装的通用 OpenSpec 技能，不是本技能自己写的，有它自己一套"遇到阻塞就 `AskUserQuestion`
问人"的规则）：**本技能是无人值守运行，这种情况下不能有人来回答它的问题**——不要替它猜一个答案
硬答过去，也不要因为它"没有明确失败"就当成完成继续往下走 `VERIFY`。按 `EXPLORE_NEXT`"探索未能给出下一个
change"那一段同样的处理方式：把状态文件中的 `status` 设为 `paused`，在 Iteration Log 追加一行说明
"APPLY 被 openspec-apply-change 自身的 guardrail 阻塞"及它具体想问什么，发 `PushNotification`
（消息类似 `spec-loop paused: openspec-apply-change blocked on <change-name> waiting for a
human decision — <one-line summary of its question>. Needs your review.`；无 `PushNotification`
时改为在本轮输出中醒目打印），以哨兵行 `LOOP_STATUS: PAUSED` 结束本轮。不要提交，也不要继续循环。

**提交（只提交，不推送）：** 实现代码在 `VERIFY`（以及需要时的一次 `FIX`）之后随 `ARCHIVE`
一起推送——这里**不要 `git push`**。`openspec-apply-change` 返回后，检查这次调用实际完成了几个任务：

- **通常情况**（它一次性做完了全部剩余任务）：直接为这次 change 的实现提交一次即可，不必为了凑"每个任务一个 commit"而拆分已经一次性完成的工作：

  ```bash
  git add -A
  git commit -m "feat(<scope>): implement <change-name>"
  ```

- **如果任务是分批完成的**（比如 `openspec-apply-change` 中途报错停下、或你自己分成了多次调用）：每完成一批就提交一次（同样不推送），不要攒到最后一批才做第一次提交；commit message 里必须写清这一批具体完成了 `tasks.md` 里的哪几项（任务编号或简短描述），不要每批都用一模一样的消息——VERIFY 步骤要靠 commit message 反推"这次 change 实际做了什么"，消息不带批次信息会让它没法区分：

  ```bash
  git add -A
  git commit -m "feat(<scope>): implement <change-name> (tasks 1-2 of N)"
  ```

### VERIFY

本技能**不**依赖 OpenSpec 自带的 `openspec-verify-change` 技能——那只在目标项目的全局
OpenSpec 配置已切换到 `profile: custom` 并在 `workflows` 中加入了 `verify` 时才存在，
本技能不应要求用户为此做额外配置（已确认：默认的 `core` profile 不包含它）。取而代之，
用 `Agent` 工具派生一个全新的、独立的子代理——普通的 `general-purpose`，**不是** fork，
因为它绝不能共享 APPLY 步骤的上下文。它同时承担两件事：**对照 spec 验证**（任务是否真的做了、
需求是否满足）和**代码 review**（正确性、安全与健壮性、测试质量）。**只跑一次**，结果只决定要不要
`FIX` 一次，不决定流程能不能往下走。使用以下确切提示（填入 `<change-name>`）：

```
Verify the OpenSpec change "<change-name>" at openspec/changes/<change-name>/ against its own
artifacts. Read proposal.md, the spec deltas, design.md, and tasks.md in that folder. Your working directory is already the project root. Then look at git log / git diff for the commits
made for this change to see what was actually implemented — those commits follow the pattern
"docs: propose <change-name>", "feat(<scope>): implement <change-name>" (the normal case — one
commit covering everything openspec-apply-change did in a single pass) or
"feat(<scope>): implement <change-name> (tasks N-M of K)" (the batched case — multiple commits,
each covering only the tasks it names). Don't assume every task has its own commit — reconstruct what was actually done
from however many commits exist and what each one's message says it covers. The implementation
commits are local only (not pushed yet), so read them from the local git log — don't
compare against origin. If the project has a test suite or build command, run it.

Do two things:
1. Spec verification: every checked-off task in tasks.md was actually done, every requirement /
   scenario in the spec deltas is met, and the code follows design.md.
2. Code review of the diff this change introduced (read the surrounding code and callers, not just
   the diff hunks): correctness (logic errors, edge cases, error handling, concurrency, resource
   leaks, breaking existing callers), security and robustness (input validation, injection,
   authz, secrets, unsafe data migrations, missing timeouts), and test quality (new tests actually
   assert the new behavior; no existing tests skipped, deleted, or loosened).

Report every issue you find, each tagged CRITICAL, WARNING, or SUGGESTION. Every CRITICAL and
WARNING must state a concrete trigger scenario (what input/state produces what wrong result);
don't report guesses you can't give a trigger for, and don't escalate style preferences.
- CRITICAL: a task checked off in tasks.md that wasn't actually done, a spec requirement that isn't
  met, a failing test/build, code that contradicts design.md, a bug that breaks the main path or
  corrupts data, an exploitable security hole, or existing tests skipped/deleted/loosened to pass.
- WARNING: a task still unchecked, a minor deviation from spec that doesn't break functionality,
  a real but edge-case bug, new or changed behavior with no test assertion covering it.
- SUGGESTION: style or clarity improvements, optional follow-ups.

End your report with exactly one line: "VERDICT: PASS" if you found zero CRITICAL issues, or
"VERDICT: FAIL" if you found one or more.
```

把结果映射到 `yueban-spec-loop` 自己的判定：**PASS** 当且仅当子代理报告的最后一行是
`VERDICT: PASS`（零个 CRITICAL 问题），否则为 **FAIL**。子代理调用本身失败、没拿到报告时，记为
**UNVERIFIED**，不重试，直接进入 `ARCHIVE`，这一点作为已知缺口写进留痕。无论哪种结果，都把
CRITICAL/WARNING/SUGGESTION 条目记录到 Iteration Log 的 Notes 列中。

- **PASS** → `ARCHIVE`。WARNING 不修，随归档写进 commit message 留给人看。
- **FAIL** → `FIX` 一次，然后不管修得怎样都 `ARCHIVE`。

**需要记住、并在用户问起时告知的注意事项：** 这个验证器与 APPLY 步骤是同一个底层模型，
只是处于一个全新的上下文中，而不是一个独立训练出来的检查器。它能可靠地捕捉到遗漏的任务、
明显的 bug 和测试/构建失败；但对于 APPLY 步骤与本验证器恰好共有的某种误解，它并不能可靠地
发现。而且它只跑一次，`FIX` 的修改不会被再次验证（只跑构建/测试）。把它当作一个真实但不完整的
安全网——它不决定流程能不能往下走，也不代替人在合并前看 diff。

### FIX（FAIL 时，只修一次）

根据验证器报告的 **CRITICAL** 问题修订实现（WARNING/SUGGESTION 不修，只记录）。逐条核实：真实存在
就修；核实后是误报的不改，记下具体理由；修不了的（需要产品决策、改动面超出本 change）如实记为
没修。不能靠删除/跳过测试、放宽断言来"修"。修完如果项目有构建/测试命令就跑一次；这次修改把它
改坏了就针对性修一次再跑，还是不行也继续往下走。**不再跑第二次 VERIFY。**

在 Iteration Log 追加一行（`fix`、`FAIL`，Notes 中逐条写 CRITICAL 的处理结果：已修（未经复核）/
误报及理由 / 没修及原因，以及修完后构建/测试是否通过），然后只提交不推送：

```bash
git add -A
git commit -m "fix(<scope>): address verifier feedback on <change-name>"
```

然后转到 `ARCHIVE`。

### ARCHIVE（总是执行）

直接运行普通 CLI 而不是某个 AI 技能——归档是纯机械操作：

```bash
openspec archive <change-name> --yes
```

（只有当该 change 没有 spec deltas 时——例如纯文档/基础设施改动——才加 `--skip-specs`。）
这会把 change 文件夹移动到 `openspec/changes/archive/YYYY-MM-DD-<change-name>/`，并在同一步
更新主 spec。

**提交并推送：** 这次 push 会把本 change 之前只留在本地的实现/修复提交一起推上去。**已知缺口**
包括：没修或修不了的 CRITICAL、被判为误报的 CRITICAL（附理由，供人复查）、`FIX` 后构建/测试仍未
通过、验证器调用失败（UNVERIFIED）。有已知缺口时标题行末尾加 ` [known gaps]`，并在正文里逐条列出；
WARNING 和已修（未经复核）的 CRITICAL 也列在正文里（某一段为空就省略那一段）：

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore: archive <change-name>[ [known gaps]]

Verifier: <PASS | FAIL, fixed once | UNVERIFIED>
Known gaps:
- <每一条已知缺口>
Fixed after verification (unreviewed):
- <每一条已修的 CRITICAL>
Warnings (not fixed):
- <每一条 WARNING>
EOF
)"
git push || git push -u origin HEAD
```

然后：`total_changes_completed` 加一，向 Iteration Log 追加一行（`archived`、`PASS` / `FAIL→fixed` /
`UNVERIFIED`，有已知缺口时在 Notes 注明 `known gaps`）。有已知缺口时，`changes_with_known_gaps` 加一，
并把每一条缺口追加到状态文件的 `# Known gaps` 小节（不要写进 Carry-forward notes——那一节每次
`EXPLORE_NEXT` 都会被整段覆写，写在那里的缺口下一轮就丢了）。如果这个 change 本身就是为了修掉
之前的某些缺口，把 `# Known gaps` 里对应的行划掉并注明 `fixed by <change-name>`。转到 `CHECK_GOAL_DONE`。

### CHECK_GOAL_DONE

阅读 Completion Criteria 和完整的 Iteration Log，判断 goal 现在是否已满足。

- **标准已满足** → 把状态文件中的 `status` 设为 `done`，然后：

  ```
  PushNotification({
    message: "spec-loop done: '<goal_slug>' complete — <N> changes archived (<changes_with_known_gaps> with known gaps). Review before merging further.",
    status: "proactive"
  })
  ```

  （如果当前上下文中没有 `PushNotification`，改为在本轮输出中醒目地打印这条消息。）

  以 `LOOP_STATUS: DONE` 结束本轮。
- **标准未满足，`total_changes_completed < max_changes`** → 以 `LOOP_STATUS: CONTINUE`
  结束本轮（下一轮迭代重新进入 `EXPLORE_NEXT`）。
- **标准未满足，`total_changes_completed >= max_changes`** → 把 `status` 设为 `paused`，
  然后：

  ```
  PushNotification({
    message: "spec-loop paused: hit max_changes (<N>) without meeting completion criteria for '<goal_slug>'. Review scope.",
    status: "proactive"
  })
  ```

  （如果当前上下文中没有 `PushNotification`，改为在本轮输出中醒目地打印这条消息。）

  以 `LOOP_STATUS: PAUSED` 结束本轮。

## 与 `/loop` 组合

本技能自己从不调用 `ScheduleWakeup`——它每次调用只运行状态机的一轮迭代，并以上述三条
哨兵行之一结束本轮。要实现无人值守运行，由用户把它包在内置的 `/loop` 技能里
（`/loop /yueban-spec-loop <goal>`），由后者负责实际的调度决策。让哨兵行始终是本轮的最后一行，
以便清晰可辨。

**已于 2026-07-06 验证：** `/loop` 自己的动态模式说明中明确写道，要停止循环，它会省略
`ScheduleWakeup` 调用——它不会自行重新触发。既然本技能从不自己调用 `ScheduleWakeup`，
`/loop` 就不会在 `DONE` 或 `PAUSED` 的一轮之后安排下一次触发。**尚未做**的是一次实际把
`yueban-spec-loop` 端到端包在 `/loop` 里、有人监督的运行（这两个机制是分别验证的，还没有在
同一次运行中一起验证过）——在小目标上先做一次有人监督的运行，验证通过后再在大目标上信任
它（见本技能的设计文档
`docs/superpowers/specs/2026-07-06-loop-openspec-design.md` 中的 Testing plan）。

## 超出范围（v1）

- 不支持 Codex CLI / Gemini CLI。
- 不负责引导安装 OpenSpec——目标项目必须已经搭建好 `openspec/`。
- 没有 git worktree 隔离。
- 不支持多 goal 并发。
- 没有比同一模型更强的验证机制。
