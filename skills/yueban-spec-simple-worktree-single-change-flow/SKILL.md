---
name: yueban-spec-simple-worktree-single-change-flow
description: 'Run one OpenSpec change through the lightweight flow in its own git worktree, then fast-forward the base branch (no push). Only when the user names this skill or asks for the worktree flow.'
license: MIT
compatibility: Requires the openspec CLI (on PATH), git 2.20+, bash, and the yueban-spec-simple-single-change-flow skill. No Workflow tool needed; works in any agent client.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Skill, Agent, AskUserQuestion
---

# OpenSpec 单 change 轻量流程（worktree 隔离版）

## 何时使用与边界

在独立 git worktree 里跑 [`yueban-spec-simple-single-change-flow`](../yueban-spec-simple-single-change-flow/SKILL.md)，做完后以 fast-forward 的方式合回基线分支（只在本地，不 push）。只有当用户用自己的话明确点名本 skill，或明确要求"在 worktree 里 / 隔离地 / 并行地"推进某一个 OpenSpec change 时才调用；用户只说"推进这个 change"时用不带 worktree 的版本，分不清就先问。它会改代码、提交并移动基线分支。

和不带 worktree 的版本的区别只有两点：**在哪儿做**（主工作区下的 `.worktrees/<change>`，分支 `spec/<change>`）和**做完怎么落回基线分支**（跟上最新基线——一般 rebase，改了 submodule 时 merge——再在仓库级的锁里 fast-forward）。中间 review spec → 修 → apply → review 代码 → archive → commit 那一段原样委托给 `yueban-spec-simple-single-change-flow`，本 skill 不重新实现。

因此多个 change 可以同时各跑一份本 skill（多开几个终端会话，或由 [`yueban-spec-simple-worktree-roadmap-flow`](../yueban-spec-simple-worktree-roadmap-flow/SKILL.md) 派 subagent），互不踩工作区。

**项目钩子**：仓库根目录提交了 `.yueban/config` 时（只认基线分支上已提交的那份；主工作区有这个文件却没提交时 `start` 会 BLOCKED），`start` 每次建好或复用 worktree 后跑其中的 `setup` 命令（代替内建的 `git submodule update --init`），`cleanup` 删 worktree 前跑 `teardown` 命令。项目用它给 worktree 准备独立的运行环境（依赖、端口、数据库等）、把 submodule 签出到 change 分支上。它还可以用 `protect` 列出不允许当基线的分支（如团队的集成分支），`start` 会拒绝。格式和约定见 `wt.sh --help`。

**落回锁**：`integrate` 和 `lock` 拿的是最外层父仓库的 `<git common dir>/yueban-spec-integrate.lock`（在 submodule 里跑也是这把）。它是公开约定，写全在 `wt.sh --help` 里：路径、owner 文件首行、token 格式、释放前核对 token、接管的步骤。项目里别的会快进基线分支或在基线分支上提交的工具（比如项目自己的 worktree 脚本），按同一约定持有这把锁，就和 `integrate` 互斥；所有持锁方要在同一台机器上（按进程号判断死活）。持锁进程已经不在的锁，下一个等锁的会接管；`lock` 拿的手动锁（pid 为空）和没有 owner 的锁不会被接管。

**改 submodule 的 change**：worktree 里的 submodule 签出在 `spec/<change>` 分支上、并且和主工作区的 submodule 是同一个仓库（`start` 输出 `SUBMODULE_ON_BRANCH=<路径>`，一般由 setup 钩子做到）时，submodule 里的提交随 change 一起落回：`integrate` 先把这些 submodule 里和基线同名的分支 fast-forward，再落父仓库，父仓库失败就把 submodule 退回去。没有 `SUBMODULE_ON_BRANCH=` 的 submodule 是 detached HEAD，改了它的 change 落不回去，用不带 worktree 的版本做。

## 输入

- change 名必须明确。用户没说是哪一个，先问，不要自己去 `ROADMAP.md` 里挑。
- 基线分支：默认是调用时所在的分支；用户另有指定，或作为 subagent 被派出时（派活方会给出基线），一律显式传 `--base <branch>`。

## 脚本

worktree 的创建、落回、清理都封装在 [`scripts/wt.sh`](scripts/wt.sh)。下文的 `<WT>`、`<WORKTREE>`、`<ORIGIN>`、`<BASE>` 都是占位符：**写命令时替换成实际的绝对路径/名字，不要用 shell 变量**——agent 每次调用 Bash 可能都是新 shell，`cd "$WORKTREE"` 在变量为空时会静默留在当前目录。

输出里 `KEY=value` 形式的行供读取。退出码：`0` 完成；`1` 用法错误（参数写错，改正后重跑）；`2` BLOCKED（把消息原样报给用户，不要用别的 git 命令绕过；除非消息另有说明，什么都没改）；`3` 只出现在 `integrate`，表示需要先跟上基线（NEEDS_REBASE 或 NEEDS_MERGE，见第 3 步）。`integrate` 和 `lock` 可能要等锁（最多 540 秒），项目有 setup 钩子时 `start` 也可能跑很久（安装依赖等），**调用这三个命令时把 Bash 超时设到 600 秒**。

```bash
<WT> start <change> [--base <branch>]   # 建 .worktrees/<change>（已存在则复用），输出 WORKTREE= / BRANCH= / BASE= / STATE= / AHEAD=，可能还有 RECREATED=1、每个随 change 落回的 submodule 一行 SUBMODULE_ON_BRANCH=
<WT> integrate                          # 在 change 的 worktree 里跑：把基线分支 fast-forward 到本分支，输出 HEAD=
<WT> cleanup <change>                   # 在 worktree 外跑：先跑 teardown 钩子（worktree 目录已不在时跳过），再删 worktree 和 spec/<change> 分支（含 submodule 里的）
<WT> landed <change> [--base <branch>]  # 只读：这个 change 是否已在基线上 archive，输出 LANDED=yes / no / unknown
<WT> status                             # 只读：所有 spec/* 分支及其 worktree 的状态、锁的持有者
<WT> lock / <WT> unlock <token>         # 手动拿/放落回锁（roadmap 流程改 ROADMAP.md 时用）
```

`start` 输出的 `STATE=`：

| STATE | 含义 | 接着做 |
|---|---|---|
| `new` | 刚建好的 worktree | 第 2 步 |
| `in_progress` | 复用上次的 worktree，change 还没 archive | 看 `git log refs/heads/<BASE>..HEAD` 和 `git status` 判断单 change 流程做到哪，第 2 步从断点接着做 |
| `archived` | 已 archive 并提交，还没落回 | 第 3 步 |
| `integrated` | 已经落回基线，只差清理 | 第 4 步 |
| `rebasing` | 上次停在 rebase 中途 | 在 worktree 里 `git status` 看冲突，解决后 `git rebase --continue`（解决不了就 `git rebase --abort`），然后第 3 步 |
| `merging` | 上次停在 merge 中途（NEEDS_MERGE 之后） | 在 worktree 里 `git status` 看冲突，解决后 `git commit --no-edit`（解决不了就 `git merge --abort`），然后第 3 步 |

`start` 还输出 `RECREATED=1` 时，说明 worktree 目录是重新签出的，依赖等环境都没了（setup 钩子会重新准备它负责的部分），先做第 2 步第 1 条再接着做。

`start` 的 setup 钩子失败时 BLOCKED：新建的 worktree 和分支会被撤掉，复用的原样保留；把钩子的输出报给用户。

改了 `wt.sh` 后跑 `scripts/selftest.sh`（临时目录里的一次性仓库，不碰别处），全部 `ok` 才算通过。

## 硬规则：命令必须在 worktree 里执行

从第 1 步拿到 `WORKTREE` 起，**每一条** Bash 命令都以 `cd "<WORKTREE 的绝对路径>" && ` 开头（或用 `git -C "<绝对路径>"`），路径直接写进命令里。Read/Edit/Write 的路径也必须以这个绝对路径开头。agent 的 shell 每次调用后 cwd 可能被重置回主工作区，这时 `git commit`、`openspec archive` 会直接落到基线分支上。

**`openspec archive` 和每次 `git commit` 之前**，在同一条命令里先断言分支，断言失败就不会执行后面的操作。在 submodule 里提交也一样，断言的是那个 submodule 的分支：

```bash
cd "<WORKTREE>" && [ "$(git symbolic-ref -q --short HEAD)" = "spec/<change>" ] && openspec archive <change> -y
cd "<WORKTREE>/<submodule>" && [ "$(git symbolic-ref -q --short HEAD)" = "spec/<change>" ] && git commit ...
```

调用单 change 流程时把这两条规则原样交代给它。

## 流程

### 1. 开 worktree

1. `command -v openspec`。**直接被用户调用时**，再确认主工作区（基线分支签出的地方）`git status --short` 为空（不干净先问用户——没提交的东西 worktree 里看不到，也会挡住后面的 fast-forward）；**作为 subagent 被派出时跳过这一条**（派活方已经检查过，主工作区这时可能正被它持锁修改）。
2. 跑 `<WT> start <change> [--base <BASE>]`。BLOCKED 时把原因讲给用户：常见的是 change 的 spec 还没提交到基线分支上、`.worktrees/` 没被 git-ignore（问用户是否把 `.worktrees/` 加进 `.gitignore` 并单独提交）、基线分支是 detached HEAD、传入的 `--base` 和这个分支上次记录的基线不一致。
3. 按上表的 `STATE` 决定从哪一步接着做，不要删了 worktree 重建。
4. 记下 `WORKTREE`、`BASE`、主工作区路径 `ORIGIN` 和 `<WT>` 的绝对路径。

### 2. 准备环境并跑单 change 流程

1. 新 worktree 里没有依赖和被 ignore 的本地文件。项目有 setup 钩子时，它负责的部分 `start` 已经做完；其余的按项目文档准备（安装依赖等）；项目自己提供 worktree 初始化脚本、又没配成钩子的照它的来。构建/测试必需、被 ignore 的本地配置（如 `.env`）可以从 `ORIGIN` 复制过来，但不要提交。`openspec-apply-change` 如果没提交进仓库（worktree 里没有 `.claude/skills/openspec-apply-change/`），仍可以直接用 `Skill` 调用（skill 列表来自会话本身），前置检查不用因此停下。
2. 准备完 `git status --short` 必须为空。安装依赖改写了 lockfile 等被跟踪的文件：`git checkout -- <file>` 还原；生成了没被 ignore 的文件：问用户是否加进 `.gitignore`（subagent 模式下按 BLOCKED 返回）。
3. 用 `Skill` 调用 `yueban-spec-simple-single-change-flow`，**显式传入 change 名**，说明：是被本 skill 调用的；在 worktree `<WORKTREE>` 的 `spec/<change>` 分支上；上面的两条硬规则；有 `SUBMODULE_ON_BRANCH=` 时，还要说明：submodule 里的改动在该 submodule 的 `spec/<change>` 分支上提交，并且**要在父仓库里提交 submodule 指针**（`git add <submodule 路径>`，和父仓库的改动一起或单独提交）——这一点替换掉单 change 流程里"指针先不暂存"的规则：本流程只在本地落回、不推送，落回时 `integrate` 要求父仓库记录的指针就是 submodule 的提交；以后推送时先推 submodule、再推父仓库（例如用 `yueban-git-safe-sync`）。所以按 `yueban-git-commit`「Handling submodules」记录指针时，跳过"submodule 提交已推送"那项检查，保留"指针只能前进"那项，也不要推送。另外，单 change 流程的代码 review 和测试要覆盖每个 `SUBMODULE_ON_BRANCH` 里的改动（父仓库的 diff 里 submodule 只显示成一个指针变化），在 submodule 目录里看 diff、跑它自己的测试。它的前置检查（在分支上、工作区干净）在 worktree 里同样成立。它收尾里的"然后停下"指的是不要接着做下一个 change——在本 skill 里，它提交并汇报完之后**必须继续第 3、4 步**，否则分支既没落回基线、worktree 也没清理。

实施中发现必须改某个 submodule 里的内容，而它不在 `SUBMODULE_ON_BRANCH=` 里：停下来问用户（subagent 模式下按 BLOCKED 返回），建议改用不带 worktree 的版本，或者给项目配一个把 submodule 签出到 change 分支上的 setup 钩子。

### 3. 落回基线分支

先确认 change 已经 archive **并提交**（`git status --short` 为空、`openspec/changes/<change>/` 不存在）。archive 了但没提交：回到单 change 流程的提交步骤补上。然后跑 `cd "<WORKTREE>" && <WT> integrate`（Bash 超时 600 秒）：

- 退出码 `0`，输出 `INTEGRATED: ...`：基线分支已 fast-forward 到本分支；基线签出在某个工作区时，那里的文件也一起更新了。输出 `ALREADY_INTEGRATED` 表示之前已经落回过。两种情况都记下 `HEAD=` 的值，到第 4 步。
- 退出码 `3` 且输出 `SYNC=merge`（NEEDS_MERGE，本分支改了 submodule）：别的 change 先落回了，或者基线在某个 submodule 里前进了。**用 merge，不要 rebase**——rebase 会改写 submodule 的提交，父仓库历史里记录的指针就指向了最终会丢失的提交。按 `SYNC_REPO=` 的顺序（submodule 在前、父仓库 `.` 最后），在每个仓库里 `git merge --no-edit refs/heads/<BASE>`：
  - submodule 里有冲突按两边的意图解决后 `git commit --no-edit`；父仓库里 submodule 路径冲突时 `git add <路径>`（取 submodule 当前的提交）。实在解决不了：`git merge --abort`，停下来问用户（subagent 模式下按 BLOCKED 返回）。
  - merge 完父仓库里 submodule 还显示有改动（`git status`）：submodule 有父仓库没记录的提交时 `git add <路径> && git commit` 记录指针；submodule **落后于**父仓库记录的提交时（另一个 change 的 submodule 提交随 merge 进来了）不要记录——那会把别人的改动退回去——`integrate` 会自动把它 fast-forward 过去。
  - 然后和下面 NEEDS_REBASE 一样重跑构建+测试、再 `integrate`。父仓库不需要 merge（`SYNC_REPO=` 里没有 `.`）时，只记录指针即可。
- 退出码 `3` 且输出 `SYNC=rebase`（NEEDS_REBASE）：别的 change 先落回了。rebase 后 `SUBMODULE_ON_BRANCH` 里的 submodule 可能落后于父仓库记录的提交，`integrate` 会自动 fast-forward 它们，不要 `git add` 记录旧指针。输出里的 `INCOMING_PATHS` 是基线新增改动涉及的文件。`git rebase refs/heads/<BASE>`（写全 `refs/heads/`，基线有同名 tag 时 `git rebase <BASE>` 会 rebase 到 tag 上，永远落不回）；仓库有 `.gitmodules` 且没有 setup 钩子时接着 `git submodule update --init --recursive`。
  - 有冲突就按两边的意图解决（另一个 change 已经 archive 的 spec 在 `openspec/specs/` 下，以它为准合并，不要丢掉对方的改动）。实在解决不了：`git rebase --abort`，停下来问用户（subagent 模式下按 BLOCKED 返回），worktree 原样保留。
  - rebase 后**重新跑项目的构建+测试**（这个组合没被测过），失败就修，修完提交。例外：`INCOMING_PATHS` 只有 `openspec/` 下的文件（比如 roadmap 流程提交的 `ROADMAP.md`）时不用重跑。
  - 然后再跑 `integrate`。锁里只做检查和移动基线，rebase 和测试都在锁外，所以并行的 change 多时可能来回几次。**连续 5 次退出码 3**（NEEDS_REBASE 或 NEEDS_MERGE）还落不回：停下来报告（subagent 模式下按 BLOCKED 返回），说明是在和哪些 change 抢。
- 退出码 `2`：原样报给用户。常见的是：主工作区有未提交的改动（会和 fast-forward 冲突；主工作区的 submodule 有没记录进父仓库的提交也算）；submodule 有未提交的改动、或指针没在父仓库提交；落回会覆盖主工作区里被 ignore 的本地文件（如 `.env`）；分支里混进了属于别的本地分支的提交（被 rebase 到了基线以外的分支上）；基线分支正在别处 rebase；锁被占用太久（消息里有持有者；持有进程已经不在的锁会被自动接管，剩下的是还在跑的进程、手动 `lock` 的锁、没有 owner 的锁，或者消息里说接管卡住了、锁目录删不掉的；确认没有别的流程或工具在落回、改基线，才可以删锁目录和消息里提到的 `.takeover.*` 目录）。

### 4. 清理

跑 `cd "<ORIGIN>" && <WT> cleanup <change>`。它只在分支（包括 submodule 里的 `spec/<change>`）已完全落到基线分支上、worktree 干净时才删：先跑 teardown 钩子（有的话），再删 worktree、父仓库和主工作区各 submodule 里的 `spec/<change>`。BLOCKED 就报给用户，不要 `--force` 绕过；teardown 钩子失败时什么都没删，按输出修好后重跑。

## 收尾

向用户汇报：单 change 流程的汇报内容（已知缺口放最前面、替用户拍板的决定、spec 和代码 review 修了什么、测试结果）、最终落到基线分支上的 commit hash（`integrate` 输出的 `HEAD=`）、rebase 时解决过的冲突，并提醒**基线分支只在本地前进了，还没推送**。

然后停下，不要自己接着做下一个 change。**例外**：被 `yueban-spec-simple-worktree-roadmap-flow` 在同一个会话里直接调用时（它没法派 subagent、一个一个做的情况），汇报完回到 `<ORIGIN>`，把控制权交回去。

**作为 subagent 被调用时**（如被 `yueban-spec-simple-worktree-roadmap-flow` 派出）：没法问用户。凡是本 skill 或单 change 流程里写着"问用户/停下来问"的地方，一律改为停止并在最终回复里返回，worktree 原样保留。最终回复的**第一行**固定为下面二选一（前缀就是 `FLOW_RESULT:`，不要写成别的），后面再跟上面的汇报内容：

```
FLOW_RESULT: DONE <change> <HEAD= 的 commit hash>
FLOW_RESULT: BLOCKED <change> <一句话：卡在哪一步、需要用户决定什么>
```

`integrate` 成功（含 `ALREADY_INTEGRATED`）就是 DONE——之后 `cleanup` 被 BLOCKED 也返回 DONE，在汇报里写明没清理掉的 worktree 路径和原因。

## 已知坑

- 命令里用 `$WORKTREE` 这类 shell 变量，或依赖上一次 `cd` 还有效，或用主工作区的绝对路径去 Read/Edit：改动和提交落到了主工作区的基线分支上——见上面的硬规则。
- change 的 spec 只在主工作区里改了没提交，worktree 里看不到：`start` 会 BLOCKED，先提交。
- 并行的几个 change 改到同一处时，后落回的那个要 rebase 解决冲突；冲突多的 change 不适合并行，排队做更省事。
- `integrate` 会 fast-forward 主工作区里签出的基线分支：并行流程跑着的时候，不要在主工作区手动改文件，否则落回会被 BLOCKED。
- `integrate`/`lock` 用了默认的 120 秒 Bash 超时，等锁时被工具杀掉：调用时设 600 秒。
- 不要手动 `git worktree remove --force` 或 `git branch -D spec/<change>`：没落回的提交会丢，teardown 钩子也不会跑，用 `cleanup`。
- 改了 submodule 的 change 在 NEEDS_MERGE 时用了 rebase：父仓库的历史指向被改写前的 submodule 提交。`git rebase --abort`（还在中途时），或者让用户决定怎么恢复；不要接着落回。
- submodule 里提交了却没在父仓库记录指针：`integrate` 会 BLOCKED（"not at the commit"），`git add <路径> && git commit` 后重跑。worktree 目录被误删时，再跑一次 `start` 会把分支重新签出来，提交都还在。
