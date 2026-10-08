---
name: yueban-spec-simple-single-change-flow
description: 'Lightweight flow for one OpenSpec change: review the spec, fix, apply, review the code, archive, commit (no push). Only when the user names this skill or asks for the lightweight flow.'
license: MIT
compatibility: Requires the openspec CLI (on PATH), git, and the openspec-apply-change skill (installed by `openspec init`/`openspec update`). No Workflow tool needed; works in any agent client.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Skill, Agent, AskUserQuestion
---

# OpenSpec 单 change 轻量流程

## 何时使用与边界

轻量版单 change 流程：review 整个 spec → 修掉问题 → apply → review 本地改动的代码 → archive → commit（不 push）。只有当用户用自己的话明确点名本 skill，或明确要求用"轻量/简单流程"推进某一个 OpenSpec change 时才调用。不要从一般性 OpenSpec 讨论、提到 ROADMAP.md 或 openspec/changes/ 推断适用；它会改代码并真实 commit。用户说"推进下一个 spec"这类话、分不清要的是本 skill 还是重版 yueban-spec-single-change-flow 时，先问。

把一个 pending change 从 spec 推到提交：**review spec → 修 → apply → review 代码 → archive → commit**。各步之间不停下来等确认，一口气做完。

和重版 `yueban-spec-single-change-flow` 的区别：不跑多轮多 agent workflow，spec 和代码各 review 一遍、修一遍就往下走，不写 `ROADMAP.md` 日志小节。适合前中期、spec 规模不大的项目。

## 输入

change 名必须明确。用户没说是哪一个，先问，不要自己去 `ROADMAP.md` 里挑（按顺序挑是 [`yueban-spec-simple-roadmap-flow`](../yueban-spec-simple-roadmap-flow/SKILL.md) 的事）。

## 前置检查

- `command -v openspec`；缺了就说明并停下。
- `openspec-apply-change` skill 已安装（通常在 `.claude/skills/openspec-apply-change/`）；缺了提示用户跑 `openspec update --force`。
- `git status --short` 为空。工作区不干净时先问用户怎么处理——最后一步会 `git add -A`，无关改动会被混进这次提交。
- `openspec status --change "<name>" --json` 确认 `proposal.md`/`design.md`/`tasks.md`/`specs/**/*.md` 齐全。
- 如果 `openspec/config.yaml` 存在，读一下里面的 `rules`，后面 review spec 和实施都以它为准。

## 第一步：review 整个 spec，有问题就改

自己把这个 change 的整个 spec（`proposal.md`、`design.md`、`tasks.md`、`specs/**/*.md`）review 一遍，看还有没有问题，怎么 review 自己决定。

发现的问题直接改这几份文档，不碰代码。改完跑 `openspec validate <name>`，不通过就修到通过。

文档里还没定案的 Open Questions、需要判断的产品/技术取舍，也由你自己拍板，不停下来问用户；把结论和理由写进 `design.md`，方便事后复查。

改完向用户简短列一下发现并修了什么、替用户拍板了哪些决定，然后**直接进入第二步**，不等确认。

## 第二步：apply

用 `Skill` 调用 `openspec-apply-change`，传入 change 名，让它把 `tasks.md` 全部做完。任务描述不清楚时自己判断怎么做；只有实施根本做不下去（比如缺少外部依赖或权限）才停下来问用户。

做完用 `grep -c '^- \[ \]' openspec/changes/<name>/tasks.md` 确认是 0——不要只信 apply 自己报的 `all_done`。

## 第三步：review 本地改动的代码

review 范围是这次 apply 产生的全部本地改动：`git diff HEAD` **加上** `git status --short` 里的未跟踪新文件（只看 `git diff` 会漏掉新建的文件）。纯文档类 change（改动只在 `openspec/changes/<name>/` 下）跳过这一步。

把这些改动 review 一遍，怎么 review 自己决定。发现的问题修掉；改了代码就再跑一次项目的构建+测试（没改代码不用重跑，apply 阶段已经跑过）。修不好的问题不停下来，记成已知缺口，写进 commit message，照常往下走。

只 review 一轮，不反复。修完直接进入第四步。

## 第四步：archive + commit

```bash
openspec archive <name> -y
git status --short
```

确认 change 目录已移到 `openspec/changes/archive/YYYY-MM-DD-<name>`，且 `openspec/specs/` 下对应的 spec 真的被创建/更新了，不能只看退出码。只有纯工具/文档类、本来就没有 `specs/` 的 change 才加 `--skip-specs`。

然后提交代码，**只 commit，不 push**，也不要问用户是否推送。

## 收尾

向用户汇报：已知缺口（有的话放最前面）、替用户拍板的决定、spec review 修了什么、实施和测试结果、代码 review 修了什么、commit hash，并提醒**只提交在当前分支、还没推送**。

然后停下，不要自己接着做下一个 change。**例外**：被 [`yueban-spec-simple-roadmap-flow`](../yueban-spec-simple-roadmap-flow/SKILL.md) 调用时，汇报完直接把控制权交回去。

## 已知坑

- apply 报 `all_done` 不等于任务全勾了，用 `grep` 交叉核实。
- 代码 review 只看 `git diff` 会漏掉未跟踪的新文件。
- `openspec archive` 退出码 0 不代表 spec 同步了，用 `git status` 看一眼（新建的 spec 文件未跟踪，`git diff` 看不到）。
- change 中途被用户放弃时，不要走 `openspec archive`：把目录移到 `openspec/changes/archive/$(date +%Y-%m-%d)-abandoned-<name>`，已经产生的代码改动先问用户要不要 revert，再提交。
