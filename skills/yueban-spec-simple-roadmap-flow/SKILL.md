---
name: yueban-spec-simple-roadmap-flow
description: 轻量版 ROADMAP 批量推进：按 openspec/changes/ROADMAP.md 的顺序，逐个用 yueban-spec-simple-single-change-flow 把所有待办 change 做完。只有当用户用自己的话明确点名本 skill，或明确要求用"轻量/简单流程"把 ROADMAP 剩下的 change 全部跑完时才调用。不要从一般性 OpenSpec 讨论、提到 ROADMAP.md、或只处理单个 change 的请求里推断适用；它会连续改代码并反复 commit（不 push）。分不清要的是本 skill 还是重版 yueban-spec-roadmap-flow 时，先问。
license: MIT
compatibility: Requires the openspec CLI (on PATH), git, and the yueban-spec-simple-single-change-flow skill. No Workflow tool needed.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Skill, AskUserQuestion
---

# OpenSpec ROADMAP 轻量批量推进

按 `openspec/changes/ROADMAP.md` 的顺序，把待办 change 一个一个交给 [`yueban-spec-simple-single-change-flow`](../yueban-spec-simple-single-change-flow/SKILL.md) 做完。本 skill 只负责**挑顺序**和**维护待办清单**，每个 change 具体怎么做全在那个 skill 里。

## ROADMAP.md 结构

本 skill 读写这三个待办小节（和重版 `yueban-spec-roadmap-flow` 用的格式兼容）：

- **「有依赖关系、需要按顺序执行」**：列表顺序就是执行顺序，不要自己重排。
- **「无强依赖，可随时执行 / 穿插」**：彼此没有顺序依赖的 change。
- **「阻塞中，前置条件满足前不实施」**（可选）：因外部条件（某业务上线、他方交付等）暂时不能做的 change，每条写明阻塞原因、解除条件、原位置。不在批量推进范围内。

文件里的其它小节（如「实施方式」、重版流程追加的日志小节）原样保留，不删也不追加。

文件不存在时不要凭空新建后就当"没有待办"结束——先问用户现在有没有 pending change、要不要按上面结构新建一份。

## 流程

1. `command -v openspec`；`git status --short` 为空（不干净先问用户）。
2. 读 `ROADMAP.md`，**轻量核实**一下顺序描述是否还符合代码现状：
   - 某条其实已在代码里**全部**实现：直接从待办小节删掉，单独 commit（`docs(roadmap): remove <name>, already implemented`），继续。
   - 只**部分**实现：停下来问用户怎么处理。
   - 「阻塞中」的条目看一眼解除条件是否已满足，满足的**先问用户**要不要移回原位置，同意后移回并单独 commit（`docs(roadmap): unblock <name>`）。
3. 先按顺序处理「有依赖关系」，再串行处理「无强依赖」。每个 change 通过 `Skill` 调用 `yueban-spec-simple-single-change-flow`，**显式传入 change 名**。一次只做一个，不并行。
4. 每个 change 提交后，从对应待办小节删掉它的条目，**单独 commit**（`docs(roadmap): remove <name>, archived`）——不提交的话，下一个 change 的"工作区干净"检查会被挡住。
5. 向用户简短汇报一句（刚完成的 change、commit hash、还剩几个），**然后直接继续下一个**，不等确认。
6. 两个待办小节都清空就结束。

## 中途要停下来的情况

- 子流程停下来问用户（Open Questions 未定案、产品取舍、实施阻塞、测试修不好）：等用户答复，拿到答复前不要跳到后面的 change，除非用户说"先跳过"。
- 发现某个 change 的外部前置条件不具备：说明缺什么；用户确认暂缓后，工作区里有它的未提交改动先问用户怎么处理（丢弃 / stash / 提交到 WIP 分支），再把它移到「阻塞中」（写明原因、解除条件、原位置），单独 commit（`docs(roadmap): block <name>`），继续后面的。后面依赖它的 change 一并问用户是否也移入。

## 收尾

汇报：处理了哪些 change 及各自的 commit hash（提醒都**只在本地、未推送**）；中途停下的，列出还剩哪些；「阻塞中」还有条目的，逐条列出阻塞原因和解除条件，免得被遗忘。
