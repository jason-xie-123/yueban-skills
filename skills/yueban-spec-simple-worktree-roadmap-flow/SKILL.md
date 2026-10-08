---
name: yueban-spec-simple-worktree-roadmap-flow
description: 'Run the pending changes in openspec/changes/ROADMAP.md in parallel, each in its own git worktree (commits, no push). Only when the user names this skill or asks to run the roadmap in parallel.'
license: MIT
compatibility: Requires the openspec CLI (on PATH), git 2.20+, bash, and the yueban-spec-simple-worktree-single-change-flow and yueban-spec-simple-single-change-flow skills. Parallel runs need background subagents (Claude Code's Agent tool); without them it runs one change at a time. No Workflow tool needed.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Skill, Agent, SendMessage, TaskStop, AskUserQuestion
---

# OpenSpec ROADMAP 轻量并行推进（worktree 版）

## 何时使用与边界

[`yueban-spec-simple-roadmap-flow`](../yueban-spec-simple-roadmap-flow/SKILL.md) 的并行版：按 `openspec/changes/ROADMAP.md` 把待办 change 分给多个 subagent，每个 subagent 在自己的 git worktree 里跑 [`yueban-spec-simple-worktree-single-change-flow`](../yueban-spec-simple-worktree-single-change-flow/SKILL.md)，做完各自 fast-forward 落回基线分支。只有当用户用自己的话明确点名本 skill，或明确要求"并行 / 用 worktree"把 ROADMAP 剩下的 change 跑完时才调用；用户只说"把 ROADMAP 跑完"时用串行的 `yueban-spec-simple-roadmap-flow`，分不清就先问。它会同时改多处代码、反复提交并移动基线分支（不 push）。

本 skill 只负责**排班**（按依赖关系决定哪些能同时做）、**派活**和**维护待办清单**；每个 change 在 worktree 里怎么做、怎么落回，全在 `yueban-spec-simple-worktree-single-change-flow` 里。

## ROADMAP.md 结构

完整结构见 [`roadmap-template.md`](roadmap-template.md)，和串行版格式相同、可以混用。本 skill 读写这三个待办小节：

- **「有依赖关系、需要按顺序执行」**：列表顺序是一个合法的执行顺序（每条都排在它的前置之后），不要自己重排。每条可以用 `依赖：` 字段显式写出前置——并行排班只认这个字段（语法见下）。
- **「无强依赖，可随时执行 / 穿插」**：彼此没有顺序依赖、也不被别的条目依赖的 change。
- **「阻塞中，前置条件满足前不实施」**（可选）：因外部条件暂时不能做的 change，每条写明阻塞原因、解除条件、原位置。不在推进范围内。

文件里的其它小节原样保留，不删也不追加。一个待办小节的条目删光时，按模板写回占位（「有依赖关系」写"暂无待实施 change"，「无强依赖」写"暂无"）。文件不存在时不要凭空新建后就当"没有待办"结束——先问用户现在有没有 pending change、要不要按 [`roadmap-template.md`](roadmap-template.md) 新建一份。

**`依赖：` 字段的语法**：`依赖：` 或 `依赖:` 后面跟 change 名，用 `,`、`，`、`、` 分隔；列表在第一个 `；`、`;`、`（`、`(` 或行尾结束；名字两边的反引号、`**` 去掉；`依赖：无` 表示没有前置。

## 排班规则

按依赖图排：**一个 change 的前置全部落回基线分支后，它就可以开工**；同时可以开工的，各开一个 worktree 并行做。

- **前置怎么定**：
  - 「有依赖关系」里写了 `依赖：` 的，前置就是列出的那几个。
  - **没写 `依赖：` 的，前置是本节排在它前面的所有条目**（等于串行语义）——顺序可能是用户定的，不要根据描述文字自己推断出更宽的并行度。描述里看得出可以并行、或者文字里提到了别的 change 名的，在第 3 步向用户提议补上 `依赖：`，用户同意后改好并单独提交。
  - 「无强依赖」的每一条都没有前置。
- **什么算"已落回"**：只认基线分支上的事实——`<WT> landed <change>` 输出 `LANDED=yes`（基线上 `openspec/changes/<change>/` 已不存在、`openspec/changes/archive/<日期>-<change>/` 存在）。前置还在待办里、在「阻塞中」、被跳过、BLOCKED 或 `LANDED=no`，都算不满足，它和所有间接依赖它的 change 都不派。
- **第 3 步就要停下来让用户修 ROADMAP 的情况**：`依赖：` 里的名字既不在三个小节里、`landed` 也不是 `yes`（拼错或漏写）；依赖了列表里更靠后的条目、依赖自己、形成环；依赖了「无强依赖」里的条目（让用户把它挪进「有依赖关系」并排在前面）。有问题的部分修好之前一个都不派——包括看起来无关的条目，免得 ROADMAP 改完之后排班要推翻。
- **例子**：A → B → C 之后 D、E 都只依赖 C，F 依赖 D 和 E——写成 `D — 依赖：C`、`E — 依赖：C`、`F — 依赖：D, E`。C 落回后 D、E 同时开两个 worktree；两个都落回后才开始 F（F 的 worktree 从已经包含 D、E 的基线切出）。
- **同时在跑的上限默认 3 个**，用户指定了就用用户的。BLOCKED 等答复的不占名额。可开工的多于上限时，「有依赖关系」里的优先（按列表顺序，它们通常挡着后面的 change），再按列表顺序派「无强依赖」的。
- **避开必然的冲突**：派一个 change 前，拿它和**正在跑的**以及这一轮要一起派的 change 比较：`design.md`/`tasks.md` 里明显要改同一批文件，或者 `specs/` 下有同名的 capability 目录（archive 时会改同一份 `openspec/specs/<capability>/spec.md`），就先不派它，等对方落回。对方 BLOCKED 或被跳过时，这个推迟随之解除。
- 读 tasks 时就能看出外部前置明显不具备（缺账号、缺第三方服务等）的，不派，按 BLOCKED 处理（问用户，见第 6 步）。
- 「阻塞中」的不派。

## 流程

下文 `<WT>` 指 `yueban-spec-simple-worktree-single-change-flow/scripts/wt.sh` 的绝对路径，`<ORIGIN>` 指主工作区（基线分支签出的地方）的绝对路径，`<BASE>` 指基线分支。写命令时直接替换成实际值，不要用 shell 变量。

**派活状态文件**：`<git common dir>/yueban-roadmap-state.md`（`git rev-parse --git-common-dir` 得到目录；在 `.git` 里，不会被提交）。每次派活、收到结果、用户做决定时更新它：每个 change 一行，记 change 名、状态（`running` / `blocked` / `skipped` / `done`）、agent 名或 ID、用户的答复。主会话的上下文被压缩或重开后，以它加上 ROADMAP 和 `<WT> status` 为准重建状态。全部结束后删掉它。

1. 前置检查：`command -v openspec`；`git symbolic-ref -q --short HEAD` 有输出——这就是**基线分支**；`git status --short` 为空（不干净先问用户）；`.worktrees/` 被 git-ignore（`git check-ignore -q .worktrees/x`，没有就问用户是否加进 `.gitignore` 并单独提交）。
2. 看上次中断留下的东西：
   - 读派活状态文件（有的话）。记着 `running` 的：问用户那些 subagent 是否还在跑（还在跑就不要重复派，等它们的结果）；记着 `skipped` 的：保持跳过；`blocked` 的：把记下的问题和答复带上，按第 6 步处理。
   - 跑 `<WT> status`。`STATE=integrated`（已经落回、只差清理）的：`<WT> cleanup <change>`，再按第 6 步的方式持锁把条目从 ROADMAP 删掉。其它 `spec/*`（包括 `rebasing`）：列给用户，对应的 change 派活时会从断点续上，不要删。
   - 显示落回锁被占用：确认没有别的流程在跑之后，问用户是否删掉锁目录（输出里有路径和持有者）。
3. 读 `ROADMAP.md`，检查 `依赖：`（见排班规则里"第 3 步就要停下来"的情况），并**轻量核实**一下是否还符合代码现状：
   - 某条 `<WT> landed` 是 `yes`（已经落回、条目没删掉，比如上次在删条目前中断了）：持锁删掉条目。
   - 某条其实已在代码里**全部**实现：直接从待办小节删掉，单独提交，继续。
   - 只**部分**实现：停下来问用户怎么处理。
   - 「阻塞中」的条目看一眼解除条件是否已满足，满足的**先问用户**要不要移回原位置，同意后移回并单独提交。
4. 确认能不能并行：当前客户端能派后台 subagent（Claude Code 的 `Agent` 工具）就并行；不能就告诉用户两个选择——在本会话里一个一个来（主会话自己按 `yueban-spec-simple-worktree-single-change-flow` 做完一个、回到 `<ORIGIN>` 更新 ROADMAP，再做下一个），或者由用户自己多开几个会话、每个会话跑一次 `yueban-spec-simple-worktree-single-change-flow`。
5. 按排班规则把能派的都派出去，每个 change 一个后台 subagent（`subagent_type` 用 `general-purpose`，名字/描述里带上 change 名），写进派活状态文件。prompt 里写清：
   - 用 `Skill` 调用 `yueban-spec-simple-worktree-single-change-flow`（`Skill` 不可用时，Read `<该 skill 目录的绝对路径>/SKILL.md` 照做），change 名 `<change>`，`--base <BASE>`，主工作区 `<ORIGIN>`，`<WT>` 的绝对路径；
   - 它是作为 subagent 被调用的：按那个 skill「作为 subagent 被调用时」一节执行，不问用户，最终回复第一行是 `FLOW_RESULT: DONE ...` 或 `FLOW_RESULT: BLOCKED ...`；
   - 只在自己的 worktree 里改文件，不碰主工作区，不碰 `ROADMAP.md`；每条命令都以 `cd "<WORKTREE 的绝对路径>" && ` 开头（路径写死在命令里，不用 shell 变量），archive 和 commit 前断言当前分支是 `spec/<change>`。
6. 每收到一个 subagent 的结果，**先用 git 核实，不只看它说了什么**：跑 `<WT> landed <change>`。
   - **`LANDED=yes`**（不管它报的是 DONE、格式不对，还是中途出错）：按 DONE 处理。
     1. `<WT> status` 里这个 change 还有 worktree：`<WT> cleanup <change>`（BLOCKED 就把原因记进收尾，不影响后面）。
     2. 在主工作区**持锁**更新 ROADMAP（不持锁的话，别的 subagent 恰好落回时会因主工作区不干净被 BLOCKED）：`<WT> lock`（Bash 超时 600 秒，它最多等 540 秒），记下输出的 `LOCK_TOKEN`——**没拿到锁（非 0 退出）就不要改文件、也不要 `unlock`**，把原因报给用户。拿到锁后**重新 Read** `ROADMAP.md`（落回会改写磁盘上的文件，之前读的内容可能过时），删掉条目（小节删空写回占位），`git add openspec/changes/ROADMAP.md`，`git commit`。提交失败（比如 hook 拒绝）：`git checkout -- openspec/changes/ROADMAP.md` 还原再处理——绝不能带着未提交的改动放锁。最后 `<WT> unlock <LOCK_TOKEN>`。
     3. 更新派活状态文件，向用户汇报一句（change、commit hash、有没有已知缺口、还在跑几个、还剩几个），**立刻按排班规则补派**，不等确认。
   - **`LANDED=no` 且报的是 BLOCKED**：直接或间接依赖它的 change 都先不派，其它的照常继续。把它的问题转给用户（多个同时卡住的一次问完）——**还有 subagent 在跑时用普通文字提问并结束本轮**，不要用会阻塞的提问工具，免得其它 subagent 的结果没人处理。用户答复后用 `SendMessage` 把答复发给那个 subagent，让它从断点接着做；那个 subagent 已经联系不上（比如主会话重开过）就重新派一个，prompt 里带上用户的答复——`start` 会续上原来的 worktree。用户说"先跳过"：状态记 `skipped`，worktree 保留，条目留在待办里，收尾时列出来。
   - **`LANDED=no` 且没有约定格式的回复，或中途出错**：按 BLOCKED 处理；`<WT> status` 看它的 worktree 停在哪，报给用户，不要自己进去接着改。
7. **没有在跑的 subagent、没有在等用户答复的 BLOCKED，并且按排班规则已经没有可派的条目**，就结束。被跳过、BLOCKED 的条目，以及因为前置没满足而没派的条目，都留在待办里、在收尾里列出。

主工作区在整个过程中只用来由主会话持锁改 `ROADMAP.md`；其它文件不要动，也提醒用户别动——基线分支会被各个 subagent 不断 fast-forward。用户想调整 ROADMAP，请他告诉主会话，由主会话持锁修改。**每次补派之前都从 `HEAD` 重新读一遍 ROADMAP** 并重新检查 `依赖：`；正在跑的 change 被用户挪进「阻塞中」或删掉了，问用户要不要用 `TaskStop` 停掉它。

## 中途要停下来的情况

- 发现某个 change 的外部前置条件不具备：说明缺什么；用户确认暂缓后，问用户它 worktree 里的改动怎么处理（留着 / 丢弃：确认它的 subagent 已经停下，`git -C <worktree> reset --hard refs/heads/<BASE>`、`git -C <worktree> clean -fd` 后 `cleanup`），再把条目移到「阻塞中」（写明原因、解除条件、原位置），持锁单独提交，继续别的。直接或间接依赖它的 change 一并问用户是否也移入。
- 用户要求中止：不再派新的；在跑的 subagent 用 `TaskStop` 停掉（没有这个工具就等它们返回），worktree 都保留，`<WT> status` 的结果报给用户，派活状态文件保留以便下次续上。被停掉时恰好持有落回锁的，`status` 会显示，按第 2 步的方式处理。

## 收尾

汇报：落回了哪些 change 及各自在基线分支上的 commit hash（提醒基线分支**只在本地前进、未推送**）；各 change 留下的已知缺口、替用户拍板的决定、rebase 时解决过的冲突，集中列一遍；没做完的（BLOCKED、跳过、中止、因前置没满足而没派）逐个列出 worktree 路径和卡在哪；没清理掉的 worktree；「阻塞中」还有条目的，逐条列出阻塞原因和解除条件。最后跑一次 `<WT> status`，确认没有残留的锁和已落回却没清理的 worktree。
