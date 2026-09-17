# Roadmap

本文汇总当前待实施的独立 OpenSpec 变更（均已完成 proposal/design/specs/tasks 四份产出物，状态：**待实施**）及其依赖顺序。

这是 `openspec/changes/ROADMAP.md` 的结构权威范本，供 `yueban-spec-roadmap-flow` 和 `yueban-spec-single-change-flow` 两个 skill 共同引用，避免各自文字描述跑偏。前三个小节是"待办排序"区域，由 `yueban-spec-roadmap-flow` 独占维护；后三个小节是"日志"区域，由 `yueban-spec-single-change-flow` 在它自己第四步的提交里追加维护。

## 有依赖关系、需要按顺序执行

（按依赖顺序列出需要串行处理的 change，每条注明为什么排在这个位置、依赖哪个前置 change、是否有文件交叉；如果当前为空，写明"暂无待实施 change"。）

1. **<change-name>** — <一句话说明依赖关系或文件交叉原因>

## 无强依赖，可随时执行 / 穿插

（列出彼此没有顺序依赖的 change；如果当前为空，写明"暂无可脱离顺序独立穿插的项"。）

## 实施方式

单个变更走 `/opsx:apply <change-name>`（或直接要求实施某个变更）；多个 change 一次性连续推进走 `yueban-spec-roadmap-flow`。新的待实施 change 出现后，在此按依赖关系与风险等级排定实施顺序，实施完成后移入对应 change 归档目录（`openspec/changes/archive/`），本文件不保留已归档 change 的历史记录（详见各 change 的 commit 历史与 `openspec/changes/archive/` 下的完整产出物）。

## 已解决的问题

（追加格式：`- YYYY-MM-DD [change-name] 描述发现了什么、怎么修的`。由 `yueban-spec-single-change-flow` 第四步提交时一并追加，记录 4 个评审角度实际发现并修复的问题——过期的设计前提、不自洽的描述、tasks.md 测试断言不足并已补齐等。只追加，不做任何自动清理/归档。）

## 无法自主解决的问题

（追加格式：`- YYYY-MM-DD [change-name] 当时卡在什么决策点、问了用户什么、用户的答复是什么`。由 `yueban-spec-single-change-flow` 第四步提交时一并追加，记录曾经用 `AskUserQuestion` 停下来问用户、拿到答复的决策点——即使当场就解决了，也作为决策留痕记录，不因"已解决"就不记。只追加，不做任何自动清理/归档。）

## 经验总结

（追加格式：`- YYYY-MM-DD 描述一条跨 change、跨轮次都适用的通用流程经验`。只在真正产生可复用经验时才追加，不要求每次执行都写一条；不局限于单个 change，所以不强制带 `[change-name]` 前缀。只追加，不做任何自动清理/归档。）
