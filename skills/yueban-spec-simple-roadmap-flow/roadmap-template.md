# Roadmap

本文汇总当前待实施的 OpenSpec change 及其执行顺序。

这是 `openspec/changes/ROADMAP.md` 的结构范本。「有依赖关系」「无强依赖」「阻塞中」三个待办小节由 `yueban-spec-simple-roadmap-flow` 维护：前两个是它逐个处理的待办，完成的 change 直接删除条目，不保留历史。

## 有依赖关系、需要按顺序执行

（列表顺序就是执行顺序。每条注明为什么排在这里、依赖哪个前置 change；用户为没有硬依赖的 change 指定了先后的，也可以排进本节，并注明是按用户决定。当前为空时写"暂无待实施 change"。）

1. **<change-name>** — <依赖关系或排序原因>

## 无强依赖，可随时执行 / 穿插

（彼此没有顺序依赖的 change。当前为空时写"暂无"。）

- **<change-name>** — <一句话说明>

## 阻塞中，前置条件满足前不实施

（可选。因外部前置条件（某业务上线、他方交付、需要人工完成的前提等）暂时不能实施的 change，不是 Open Questions 未定案，也不是被放弃。不在批量推进范围内；解除条件满足、经用户确认后，按原位置移回。当前为空时写"暂无阻塞项"。）

1. **<change-name>** — 阻塞原因：<……>；解除条件：<……>；原位置：<「有依赖关系」第 N 项，前置 <change-a>、后续 <change-b> / 「无强依赖」>

## 实施方式

单个 change 走 `yueban-spec-simple-single-change-flow`（review spec → 修 → apply → review 代码 → archive → 提交）；多个 change 一次性连续推进走 `yueban-spec-simple-roadmap-flow`。已完成的 change 在 `openspec/changes/archive/` 下，本文件不保留历史记录。
