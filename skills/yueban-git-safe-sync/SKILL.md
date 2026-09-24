---
name: yueban-git-safe-sync
description: '在带 git submodule 的仓库里执行 pull 或 push 时，保证每个当前维护的 submodule（从 .gitmodules 动态发现，排除 deprecated/ 前缀的历史/冻结模块）始终停留在其原有分支上（具体叫什么以项目实际约定为准），绝不因为 pull/push 而把 submodule 变成游离 HEAD（detached HEAD）或强制签出到父仓库记录的 SHA。适合"在多台机器上跑同一套项目、submodule 分支状态必须跨机器保持一致"的场景。**仅显式触发**：只有用户明确输入 `/yueban-git-safe-sync`，或明确说要用这个 skill 时才调用；用户只是随口说"pull 一下""push 一下""同步一下代码"这类泛化表述，不要自作主张联想到这个 skill——先按普通 git 操作处理或直接追问，除非用户点名。'
allowed-tools: Bash
---

# Submodule 安全同步（pull / push）

> ⚠️ **仅手动触发**：只有用户明确输入 `/yueban-git-safe-sync`，或明确点名要用这个 skill 时才执行下面的流程。普通的"帮我 pull/push 一下"不要自动联想到这里。

## 为什么需要这个 skill

用 git submodule 管理多个当前维护模块的仓库（哪些 submodule 算"当前维护"，从 `.gitmodules` 里排除路径以 `deprecated/` 开头的条目动态判断——项目如果没有这个约定，就是全部 submodule 都算）。每个 submodule 平时都签出在一个具体分支上（叫什么以项目实际约定为准），而不是 git submodule 的默认状态。

如果项目里存在已停止维护、冻结在某个分支上只作历史参考的 submodule（放在 `deprecated/` 之类的目录下），这类 submodule 天然被上面的动态发现规则排除，不需要本 skill 的"保持分支不掉 detached HEAD"这套保护逻辑，pull/push 时按普通只读参考对待即可——具体某个 submodule 为什么被冻结、后续要不要读它做同步比对，是项目自己的业务判断，不属于本 skill 关心的范围。

风险在于：git 处理 submodule 的默认命令是"按父仓库记录的 SHA 签出"，而不是"按分支拉取"：

- `git submodule update`（以及开了 `submodule.recurse` 之后 `git pull` 隐式触发的那次 update）会把每个 submodule 签出到父仓库索引里记录的那个 commit —— **这个操作本身就会把 submodule 切成 detached HEAD**，哪怕现在正停在某个分支上。
- 父仓库记录的 submodule 指针经常落后于 submodule 自己分支的最新提交（这是正常现象：你在一台机器上给某个 submodule 提交了新代码，还没来得及回到父仓库 `git add` 记录新指针）。如果直接 `git push` 父仓库而 submodule 的提交还没 push 到它自己的远程，另一台机器 pull 下来后会指向一个远程都没有的 commit。

用户同时在家和公司两台电脑上跑全部功能，一旦某个 submodule 在其中一台变成 detached HEAD 或指向了本地才有的 commit，另一台机器上跑起来的代码版本就对不上，且不容易第一时间发现。这个 skill 就是为了在 pull/push 时主动规避这两类问题。

## 核心原则

1. **submodule 的分支永远是唯一真相来源，父仓库记录的 SHA 只是一个滞后的快照。** 更新 submodule 时按分支 `fetch` + 快进（fast-forward），绝不按 SHA 签出。
2. **遇到任何异常都停下来问用户，绝不自动"修好"。** 包括：submodule 已经处于 detached HEAD、有未提交的改动、本地分支与远程分支出现分叉（既有本地独有提交又落后远程）。这些都是需要人来决定怎么合并/变基的场景，脚本不会替用户做这个决定。
3. **push 之前，先把每个 submodule 自己的提交推到它自己的远程分支，再推父仓库。** 顺序反过来就会出现父仓库记录了一个远程还没有的 commit。
4. **一次同步操作对所有 submodule 是"全部可以就全部做，有一个卡住就全部不做"**，不会出现部分 submodule 已经变了、另一些还没变的中间状态。

## 怎么用

具体的 git 操作都封装在 `scripts/sync.sh` 里（纯 bash + git plumbing，确定性强，不需要每次重新推理怎么写 git 命令）。三个子命令：

```bash
scripts/sync.sh status        # 只读，展示每个 submodule 当前分支/是否 dirty/ahead-behind
scripts/sync.sh pull          # 安全 pull
scripts/sync.sh push          # 安全 push
scripts/sync.sh push --dry-run   # 只打印计划，不实际推送
```

### 判断用户想 pull 还是 push

用户调用 `/yueban-git-safe-sync` 时可能直接说明意图（"我要 pull"/"我要 push"），也可能什么都不加。按下面顺序判断：

1. 用户消息里明确提到 pull（拉取/同步最新代码/换了台机器）或 push（推送/提交上去/同步给另一台机器），就按对应模式走。
2. 都没提到：先跑 `scripts/sync.sh status`，看当前是 ahead（有本地未推送的提交，倾向于 push 场景）还是 behind（远程有新提交，倾向于 pull 场景），据此提出一个判断并跟用户确认，而不是自己悄悄二选一执行有副作用的操作。

### pull 流程

1. 运行 `scripts/sync.sh pull`。
2. 如果它输出了 `BLOCKED: ...`（退出码 2）：**不要**尝试自己用别的 git 命令去强行绕过或"修复"这个 submodule（比如手动 checkout、reset、rebase）。把每一条 BLOCKED 原样讲给用户听，问清楚想怎么处理，处理完再重新跑一遍。
3. 成功后脚本会自动打印一次 `status`，确认所有 submodule 仍然停在原来的分支上——把这个结果简要汇报给用户即可，不用整段贴输出。

### push 流程

1. 先运行 `scripts/sync.sh push --dry-run`，看计划里哪些 submodule 有待推送的提交、父仓库是否也需要推送。
2. 把这个计划 summarize 给用户看（比如"某个 submodule 有 2 个提交要推，其余 up to date，父仓库也要推 1 个提交"），**推送属于会影响远程/对方机器可见的操作，执行前要让用户确认**，不要看到 dry-run 干净就直接自动继续推。
3. 用户确认后，再运行不带 `--dry-run` 的 `scripts/sync.sh push` 真正执行。
4. 如果出现 `BLOCKED`，处理方式同 pull：原样反馈给用户，不自作主张强推（脚本本身也不会做 force push——分叉的情况会直接 BLOCKED，需要用户先手动 pull/rebase）。

## 不在这个 skill 范围内的事

- 给 submodule 里的实际代码改动做 commit（脚本只处理"已经 commit 好、要不要 pull/push"这一层，不会替用户想 commit message 或决定要不要提交某些文件改动）。
- 已停止维护、放在 `deprecated/` 之类路径下的历史 submodule：不参与"跨机器保持分支一致"的诉求，`scripts/sync.sh` 已经把它们排除在外（通过过滤 `.gitmodules` 里 `deprecated/` 开头的路径）。
- 新增/删除 submodule、修改 `.gitmodules`：这些是结构性变更，超出"安全同步"的范围，照常手动处理。
