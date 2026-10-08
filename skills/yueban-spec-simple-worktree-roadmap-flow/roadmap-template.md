# Roadmap

本文汇总当前待实施的 OpenSpec change 及其执行顺序。

这是 `openspec/changes/ROADMAP.md` 的结构范本。「有依赖关系」「无强依赖」「阻塞中」三个待办小节由 `yueban-spec-simple-worktree-roadmap-flow`（并行）或 `yueban-spec-simple-roadmap-flow`（串行）维护，两者格式相同、可以混用：前两个是待办，完成的 change 直接删除条目，不保留历史。

## 有依赖关系、需要按顺序执行

（列表顺序是一个合法的执行顺序：每条都排在它的前置之后，串行推进时就按这个顺序做。每条用 `依赖：` 写明前置 change（多个用逗号分隔，没有写 `依赖：无`），并说明原因；并行推进时，前置全部落回基线分支的 change 就可以开工，同时可以开工的各开一个 worktree 并行做。没写 `依赖：` 的条目，并行推进时保守地当作依赖本节排在它前面的所有条目。用户为没有硬依赖的 change 指定了先后的，也可以排进本节，写成 `依赖：<上一条>（按用户决定）`——写 `依赖：无` 的话并行推进时会打破这个先后。`依赖：` 里只能写本节排在前面的 change，不能写「无强依赖」里的。当前为空时写"暂无待实施 change"。）

1. **<change-name>** — 依赖：无；<排在这里的原因>
2. **<change-name>** — 依赖：<上一条 change>；<依赖原因>
3. **<change-name>** — 依赖：<change-a>, <change-b>；<依赖原因>

（例：A → B → C 之后 D、E 都只依赖 C，F 依赖 D 和 E——D、E 写 `依赖：C`，F 写 `依赖：D, E`。C 落回后 D、E 并行，两个都落回后才开始 F。）

## 无强依赖，可随时执行 / 穿插

（彼此没有顺序依赖的 change。并行推进时，每一条都可以和其它 change 同时做，各自在独立的 git worktree 里；明显会改同一批文件的，建议挪进上一节排好先后，避免落回时的 rebase 冲突。当前为空时写"暂无"。）

- **<change-name>** — <一句话说明>

## 阻塞中，前置条件满足前不实施

（可选。因外部前置条件（某业务上线、他方交付、需要人工完成的前提等）暂时不能实施的 change，不是 Open Questions 未定案，也不是被放弃。不在批量推进范围内；解除条件满足、经用户确认后，按原位置移回。当前为空时写"暂无阻塞项"。）

1. **<change-name>** — 阻塞原因：<……>；解除条件：<……>；原位置：<「有依赖关系」第 N 项，前置 <change-a>、后续 <change-b> / 「无强依赖」>

## 实施方式

单个 change 走 `yueban-spec-simple-single-change-flow`（在当前工作区）或 `yueban-spec-simple-worktree-single-change-flow`（在独立 worktree，做完 fast-forward 落回基线分支）；多个 change 连续推进走 `yueban-spec-simple-roadmap-flow`（串行）或 `yueban-spec-simple-worktree-roadmap-flow`（并行）。已完成的 change 在 `openspec/changes/archive/` 下，本文件不保留历史记录。
