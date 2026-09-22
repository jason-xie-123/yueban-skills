---
name: yueban-loop-openspec
description: '把一个 Goal 变成一个无人值守、自驱动的 OpenSpec 循环：动态挑选下一个价值最高的 change，进行 propose/plan，实现它，用一个全新的独立 agent 验证它，归档它，并判断整个 goal 是否完成——如此重复，直到 DONE 或某个护栏暂停它以供人工审阅。仅限 Claude Code：与内置的 /loop 技能（用于调度）以及 PushNotification（用于提醒）组合使用。只在明确调用时使用——用 "/yueban-loop-openspec <目标...>" 启动，用 "/yueban-loop-openspec continue" 或裸的 "/yueban-loop-openspec" 恢复，用 "/loop /yueban-loop-openspec <目标...>" 进行完全无人值守的运行。要求目标项目已经初始化过 OpenSpec（openspec init，默认的 core profile 就够）——本技能不负责为项目引导安装 OpenSpec 本身。**注意：本技能在每个检查点会自动 commit 并 push 到 origin（与本仓库另外两个 spec 流程 skill——yueban-spec-single-change-flow、yueban-spec-roadmap-flow——"只 commit 不 push"的约定不同），因为它是设计给完全无人值守运行的；不想自动 push 到远端就不要用它。**'
allowed-tools: Bash, Read, Write, Edit, Skill, Agent, PushNotification
---

# Loop OpenSpec

## 概述

把一个大的 `Goal` 转化为在 OpenSpec changes 之上自驱动的循环：EXPLORE_NEXT → PROPOSE_PLAN →
APPLY → VERIFY → ARCHIVE（或 FIX_RETRY）→ CHECK_GOAL_DONE，如此重复，直到满足 goal 的完成
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
- **在每个检查点直接通过 `git` 提交并推送**（add/commit/push，push 到 origin 不需要额外确认）——本技能不依赖目标项目安装了
  其他任何技能（比如本仓库自带的 `yueban-git-commit`）。这是本技能区别于 `yueban-spec-single-change-flow`/`yueban-spec-roadmap-flow`（两者都只 commit、不自动 push）的关键差异：本技能是为完全无人值守运行设计的，没人在场按 `yueban-git-commit` 的"push 前确认"逻辑做确认，所以每个检查点的 push 是自动的、无提示的。
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
/loop /yueban-loop-openspec 目标：<一句话目标>。背景：<约束、现状、期望方向——一次性交代完>。完成标准：<怎么算彻底做完了>

# 启动，手动逐轮进行（每一轮由你自己重新调用）：
/yueban-loop-openspec 目标：<...>。背景：<...>。完成标准：<...>

# 恢复——从状态文件中读回一切信息，无需重新解释：
/yueban-loop-openspec continue
/yueban-loop-openspec

# 在不重启当前运行的情况下，向其追加新背景：
/yueban-loop-openspec <要追加的新背景或说明>
```

## 步骤 1 —— 查找或创建状态文件

```bash
ls openspec/loop-engineering/*/state.md 2>/dev/null
```

对用户消息分类：如果包含 目标/背景/完成标准（新的目标文本），归为**启动**；否则归为
**continue/append**（裸的 `/yueban-loop-openspec`、`/yueban-loop-openspec continue`，或任意补充背景）。
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
  Iteration Log 最后一行读取，或从 `total_changes_completed >= max_changes` 这个事实推断），
  并询问他们想如何处理。如果这条消息里用户还没有给出回答，就以 `LOOP_STATUS: PAUSED` 结束
  本轮并等待——一旦他们回复：
  - 如果是被"连续 3 次失败"护栏暂停的：一旦用户告诉你改变了什么（他们修复了某个问题，或想
    再试一次），把 `consecutive_failures` 重置为 0，设置 `status: running`，重新进入
    `VERIFY`，验证那个卡住的 change（通过 `ls openspec/changes/`（排除 `archive/`）找到它——
    尚未归档的那个就是进行中的 change）。
  - 如果是被 `max_changes` 护栏暂停的：如果用户给出新的上限，更新 frontmatter 中的
    `max_changes`，设置 `status: running`，转到 `EXPLORE_NEXT`。如果他们表示 goal 就这样
    算完成了，设置 `status: done` 并停止（不需要重新进入状态机）。
  - 不要在用户没有表态的情况下静默恢复一个暂停的运行——这正是护栏存在的全部意义。
- **Continue/append，且没有任何 `state.md` 是 `status: running` 或 `status: paused`**：
  告诉用户本项目中没有活跃的 `yueban-loop-openspec` 运行，以 `LOOP_STATUS: PAUSED` 结束本轮
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
consecutive_failures: 0
total_changes_completed: 0
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
```

## 步骤 2 —— 运行状态机的一轮迭代

`EXPLORE_NEXT → PROPOSE_PLAN → APPLY → VERIFY → (ARCHIVE | FIX_RETRY) → CHECK_GOAL_DONE`

### EXPLORE_NEXT

调用 `openspec-explore` 技能（`Skill({skill: "openspec-explore"})`），按以下方式构建问题：
基于状态文件中的 Goal、Completion Criteria、Iteration Log、Carry-forward notes，以及仓库当前
状态，下一个价值最高的 OpenSpec change 是什么？没有固定的预先路线图——每次迭代都要重新推导。
从这一步得出一个简短的 change 名称和 2-4 句理由。

`openspec-explore` 通常是与人类的对话式来回。在无人值守运行时（没有人在场回答追问），不要
等待回复——直接从探索结果中综合出你自己具体的决定，选定一个 change 名称；如果有多个候选
看起来都合理，用 Goal/Completion Criteria/Iteration Log 作为决胜依据。

**探索不出任何候选 change，但 Completion Criteria 显然还没满足**（比如探索结果认为"目标已经
无法再拆出新的 change"，但完成标准写的东西代码里还没有）：这不是 `CHECK_GOAL_DONE` 该判定
"done"的场景（"done"要求标准真的已满足），也不能假装找到一个凑数的 change 硬做下去。把
`status` 设为 `paused`，在 Iteration Log 追加一行说明"探索未能给出下一个 change"及具体原因，
发 `PushNotification`（消息类似 `loop-openspec paused: EXPLORE_NEXT found no viable next
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

### APPLY

针对 `<change-name>` 调用 `openspec-apply-change` 技能
（`Skill({skill: "openspec-apply-change"})`），它会逐一处理 `tasks.md` 中未勾选的任务。

**提交：** 每完成一个任务（或一小组直接相关的任务）后，提交并推送：

```bash
git add -A
git commit -m "feat(<scope>): implement task N of <change-name>"
git push || git push -u origin HEAD
```

不要等到 change 中的所有任务都完成才做第一次提交。

### VERIFY

本技能**不**依赖 OpenSpec 自带的 `openspec-verify-change` 技能——那只在目标项目的全局
OpenSpec 配置已切换到 `profile: custom` 并在 `workflows` 中加入了 `verify` 时才存在，
本技能不应要求用户为此做额外配置（已确认：默认的 `core` profile 不包含它）。取而代之，
用 `Agent` 工具派生一个全新的、独立的子代理——普通的 `general-purpose`，**不是** fork，
因为它绝不能共享 APPLY 步骤的上下文——使用以下确切提示（填入 `<change-name>`）：

```
Verify the OpenSpec change "<change-name>" at openspec/changes/<change-name>/ against its own
artifacts. Read proposal.md, the spec deltas, design.md, and tasks.md in that folder. Your working directory is already the project root. Then look at git log / git diff for the commits
made for this change to see what was actually implemented — those commits follow the pattern
"docs: propose <change-name>", "feat(<scope>): implement task N of <change-name>", and
"fix(<scope>): address verifier feedback on <change-name>". If the project has a test suite or build
command, run it.

Report every issue you find, each tagged CRITICAL, WARNING, or SUGGESTION:
- CRITICAL: a task checked off in tasks.md that wasn't actually done, a spec requirement that isn't
  met, a failing test/build, or code that contradicts design.md.
- WARNING: a task still unchecked, a minor deviation from spec that doesn't break functionality,
  missing but non-critical test coverage.
- SUGGESTION: style or clarity improvements, optional follow-ups.

End your report with exactly one line: "VERDICT: PASS" if you found zero CRITICAL issues, or
"VERDICT: FAIL" if you found one or more.
```

把结果映射到 `yueban-loop-openspec` 自己的判定：**PASS** 当且仅当子代理报告的最后一行是
`VERDICT: PASS`（零个 CRITICAL 问题）。否则为 **FAIL**。无论哪种结果，都把
CRITICAL/WARNING/SUGGESTION 条目记录到 Iteration Log 的 Notes 列中。

**需要记住、并在用户问起时告知的注意事项：** 这个验证器与 APPLY 步骤是同一个底层模型，
只是处于一个全新的上下文中，而不是一个独立训练出来的检查器。它能可靠地捕捉到遗漏的任务
和明显的测试/构建失败；但对于 APPLY 步骤与本验证器恰好共有的某种误解，它并不能可靠地
发现。把它当作一个真实但不完整的安全网。

### ARCHIVE（PASS 时）

直接运行普通 CLI 而不是某个 AI 技能——一旦 VERIFY 已经把过关，归档就是纯机械操作：

```bash
openspec archive <change-name> --yes
```

（只有当该 change 没有 spec deltas 时——例如纯文档/基础设施改动——才加 `--skip-specs`。）
这会把 change 文件夹移动到 `openspec/changes/archive/YYYY-MM-DD-<change-name>/`，并在同一步
更新主 spec。

**提交：**

```bash
git add -A
git commit -m "chore: archive <change-name>"
git push || git push -u origin HEAD
```

然后：把 `consecutive_failures` 重置为 0，`total_changes_completed` 加一，向 Iteration Log
追加一行（`archived`、`PASS`），转到 `CHECK_GOAL_DONE`。

### FIX_RETRY（FAIL 时）

把状态文件 frontmatter 中的 `consecutive_failures` 加一。

- **`< 3`**：向 Iteration Log 追加一行（`fix_retry (<consecutive_failures>/3)`、`FAIL`，
  Notes 中带上 CRITICAL 问题），根据验证器的 CRITICAL 反馈修订实现，提交并推送，然后回到
  `VERIFY`：

  ```bash
  git add -A
  git commit -m "fix(<scope>): address verifier feedback on <change-name>"
  git push || git push -u origin HEAD
  ```
- **`== 3`**：把状态文件中的 `status` 设为 `paused`，向 Iteration Log 追加一行
  （`fix_retry (3/3)`、`FAIL`），然后：

  ```
  PushNotification({
    message: "loop-openspec paused: <change-name> failed verification 3x — <one-line reason>. Needs your review.",
    status: "proactive"
  })
  ```

  （如果当前上下文中没有 `PushNotification`，改为在本轮输出中醒目地打印这条消息。）

  以哨兵行 `LOOP_STATUS: PAUSED` 结束本轮（见下方"与 /loop 组合"）。不要继续循环。

### CHECK_GOAL_DONE

阅读 Completion Criteria 和完整的 Iteration Log，判断 goal 现在是否已满足。

- **标准已满足** → 把状态文件中的 `status` 设为 `done`，然后：

  ```
  PushNotification({
    message: "loop-openspec done: '<goal_slug>' complete — <N> changes archived. Review before merging further.",
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
    message: "loop-openspec paused: hit max_changes (<N>) without meeting completion criteria for '<goal_slug>'. Review scope.",
    status: "proactive"
  })
  ```

  （如果当前上下文中没有 `PushNotification`，改为在本轮输出中醒目地打印这条消息。）

  以 `LOOP_STATUS: PAUSED` 结束本轮。

## 与 `/loop` 组合

本技能自己从不调用 `ScheduleWakeup`——它每次调用只运行状态机的一轮迭代，并以上述三条
哨兵行之一结束本轮。要实现无人值守运行，由用户把它包在内置的 `/loop` 技能里
（`/loop /yueban-loop-openspec <goal>`），由后者负责实际的调度决策。让哨兵行始终是本轮的最后一行，
以便清晰可辨。

**已于 2026-07-06 验证：** `/loop` 自己的动态模式说明中明确写道，要停止循环，它会省略
`ScheduleWakeup` 调用——它不会自行重新触发。既然本技能从不自己调用 `ScheduleWakeup`，
`/loop` 就不会在 `DONE` 或 `PAUSED` 的一轮之后安排下一次触发。**尚未做**的是一次实际把
`yueban-loop-openspec` 端到端包在 `/loop` 里、有人监督的运行（这两个机制是分别验证的，还没有在
同一次运行中一起验证过）——在小目标上先做一次有人监督的运行，验证通过后再在大目标上信任
它（见本技能的设计文档
`docs/superpowers/specs/2026-07-06-loop-openspec-design.md` 中的 Testing plan）。

## 超出范围（v1）

- 不支持 Codex CLI / Gemini CLI。
- 不负责引导安装 OpenSpec——目标项目必须已经搭建好 `openspec/`。
- 没有 git worktree 隔离。
- 不支持多 goal 并发。
- 没有比同一模型更强的验证机制。
