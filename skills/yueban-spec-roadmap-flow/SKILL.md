---
name: yueban-spec-roadmap-flow
description: 只有当用户用自己的话明确要求把本仓库 openspec/changes/ROADMAP.md 里整条待办全部推进完成时才调用——不是只处理一个 change，比如"把 ROADMAP 剩下的都跑完"/"连续做完剩下所有的 spec"。不要从一般性 OpenSpec 讨论、提到 ROADMAP.md、或要求处理单个 change 的场景里推断适用（单个 change 请用 yueban-spec-single-change-flow）。这是一个持续数小时、高 token 消耗、多 agent、反复 commit（不自动 push）的操作，必须由用户主动触发，不能靠 AI 推断。不确定就先问。
license: MIT
compatibility: Requires the openspec CLI (on PATH) and the yueban-spec-single-change-flow skill. This skill itself never calls Workflow directly (see allowed-tools below); yueban-spec-single-change-flow uses Workflow internally when this skill delegates each change to it via the Skill tool.
allowed-tools: Bash, Read, Edit, Grep, Glob, Skill, AskUserQuestion
---

# yueban 项目：全量 spec 推进

本仓库（yueban）用 OpenSpec 管理产品/工程改动提案，`openspec/changes/ROADMAP.md` 记录当前所有 pending change。这个 skill 负责把整个 ROADMAP 待办清空，是 [`yueban-spec-single-change-flow`](../yueban-spec-single-change-flow/SKILL.md)（只处理**一个** change）的上层编排版本。

## 什么时候才能调用这个 skill

**只有用户显式、明确地要求把 ROADMAP 剩下的 change 连续跑完时，才能调用本 skill**——比如用户直接说"把剩下的 spec 都跑完""连续做完剩下所有的"。

**不要**仅凭以下这类间接信号就自行判断要调用本 skill：

- 用户只是在讨论、查看、编辑 `ROADMAP.md`、`openspec/changes/` 目录，或某个 change 的文档内容；
- 用户要求处理**某一个具体** change（那是 `yueban-spec-single-change-flow` 的场景，处理完一个就该停下来汇报，不能因为调用了本 skill 而擅自升级成"顺便都做完"）；
- 通用的"只要有一点可能适用就该用 skill"的默认倾向（参见 `using-superpowers`）**不适用于本 skill**——这是一个会持续数小时、反复跑多 agent workflow、反复修改代码、反复真实 `git commit` 的高开销、有副作用的操作，必须由用户主动、明确触发。

不确定用户是不是这个意思时，先用 `AskUserQuestion` 确认，不要直接开始跑。

## 核心原则

- **这是唯一允许"连续做完剩下所有 change"的场景**——`yueban-spec-single-change-flow` 自身默认一次只做一个就停，本 skill 调用它时可以显式豁免这条默认限制（因为用户在调用本 skill 时已经表达了"连续做完"的意图），但仍然遵守它的其它规则（一次只处理一个 change、不并行 apply 有文件重叠风险的 change）。
- **权限不预先固化**：本 skill 不预设"生产/测试数据库操作、CI/CD 操作均无需确认"这类标准权限。如果某个 change 涉及生产数据存量数据排查/迁移等敏感操作，仍按 `yueban-spec-single-change-flow` 及仓库一般准则的要求，在当次对话里向用户确认后再执行，不能因为在跑本 skill 就默认已经获得授权。
- **每完成一个 change 都要留痕**：进度体现在 `ROADMAP.md`（由本 skill 第 6 步自己更新，`yueban-spec-single-change-flow` 本身不读写 `ROADMAP.md`）和每次 commit 里，本 skill 不额外维护一份平行的执行日志文档——不要在仓库里新建 `docs/YYYY-MM-DD-*.md` 之类的进度记录文件。
- **中途遇到需要用户拍板的事，暂停并问，不要猜**：某个 change 的 Open Questions 未定案、ROADMAP 依赖描述与代码现状不一致、发现真实 bug 但修复方案有分歧等，都要停下来用 `AskUserQuestion` 或直接提问，等回复后再继续。

## 清空 ROADMAP 待办

1. 先确认 `openspec` 命令本身在 PATH 上（`command -v openspec`）——本 skill 后续每处理完一个 change 都要靠它间接触发的 `openspec-apply-change`/`openspec validate`/`openspec archive`，缺了这个二进制会在流程跑到一半才报错，不如提前发现，向用户说明并停下。
2. 读 `openspec/changes/ROADMAP.md`（结构参照 [`roadmap-template.md`](roadmap-template.md)）。**文件不存在时**：说明这个项目还没有用这套 ROADMAP 机制管理待办（或者所有 change 都已处理完、之前从未创建过），不要凭空新建一份就当作"暂无待办"直接结束本 skill——向用户确认清楚现在到底有没有 pending change 需要处理、要不要参照 [`roadmap-template.md`](roadmap-template.md) 新建一份。
3. **轻量核实顺序/依赖描述是否还符合代码现状**（只核实排序/冲突相关的事实，不对每个 change 的完整设计前提做深度审计——那是 `yueban-spec-single-change-flow` 第一步评审角度1、3 在真正执行到该 change 时才做的事，提前几个小时做同样的事到轮值时也会过期，纯浪费）：
   - 「有依赖关系、需要按顺序执行」小节里标注的前置 change，核实是否真的还没完成（比如去看对应 capability 是否已在 `openspec/specs/` 下、或代码是否已体现该前置改动）。
   - 「无强依赖，可随时执行 / 穿插」小节里的条目，快速过一遍是否有未被文档记录、但实际会改到同一批文件/同一个数据结构的冲突（不需要逐行比对设计文档，重点看条目描述里提到的具体文件/结构，扫一眼现状是否仍如此）。
   - 发现描述与代码现状不一致（顺序判断错误、遗漏的文件冲突、某个"待实施"的 change 其实已经部分/全部实现）：**直接按代码现状更新 `ROADMAP.md`，不用停下来问用户**——以代码为准，把过期的顺序/冲突描述改对；如果是"已全部实现"，按第 6 步的方式直接从对应小节删掉该条目（`ROADMAP.md` 不再保留归档历史，见第 6 步），commit message 里写明"核实时发现已在代码中实现，跳过 `yueban-spec-single-change-flow` 流程"。更新完照常继续核实/处理下一项，不因为这类发现而暂停等待。
     - **例外**：如果某个"待实施"的 change 只是**部分**实现（不是全部），这通常意味着之前的实施半途而废或有缺陷，而不是单纯的文档滞后——这种情况不能靠猜测决定"当作已完成/当作未开始"，仍然要停下来向用户说明具体缺了什么，等用户拍板（补完剩余部分/重新走完整流程/其它处理方式）。
4. 先处理「有依赖关系、需要按顺序执行」小节（若非空），严格按记录顺序，不能跳过未完成的前置项。
5. 该小节清空后，处理「无强依赖，可随时执行 / 穿插」小节。默认**串行**逐个处理（**REQUIRED SUB-SKILL:** 从 `ROADMAP.md` 里取出具体的 change 名，通过 `Skill` 工具调用 [`yueban-spec-single-change-flow`](../yueban-spec-single-change-flow/SKILL.md) 并**显式传入该 change 名**，完整走完 校验 spec 文档→openspec-apply-change 实施→archive→commit 生命周期——`yueban-spec-single-change-flow` 本身不读、也不维护 `ROADMAP.md` 的「有依赖关系」「无强依赖」两个待办小节——它只认调用方显式传入的 change 名，挑选顺序和这两个待办小节的增删都是本 skill 自己的职责；但它第四步的提交**会**写 `ROADMAP.md`（追加底部「已解决的问题」「无法自主解决的问题」「经验总结」三个常驻日志小节，见第 6 步说明），这部分不算"不读写"的例外）；只有用户额外明确要求"并行加速"时才考虑分批并行，且分批前必须先核实候选 change 之间是否有文件级重叠（同一文件的不同区块也算重叠），有重叠的必须错开，不能真并行改代码。
6. 每个 change 走完 `yueban-spec-single-change-flow` 的第四步（提交，不自动 push）后，**由本 skill 自己更新 `ROADMAP.md`**：从「有依赖关系」或「无强依赖」对应小节删掉该 change 的条目——这两个待办小节不再保留已归档 change 的历史记录（见文件顶部「实施方式」一节的说明），完成的 change 直接删除条目，不额外新增"已归档"子小节去记录它曾经存在过。真正需要长期沉淀的发现（校验中修了什么、卡在哪个决策点问过用户什么、有没有推翻/修正立项时的技术假设）已经由 `yueban-spec-single-change-flow` 在它自己第四步的提交里，追加进 `ROADMAP.md` 底部「已解决的问题」「无法自主解决的问题」「经验总结」三个常驻日志小节（结构参照 [`roadmap-template.md`](roadmap-template.md)）——本 skill 这一步不重复处理这三个日志小节，只负责「有依赖关系」「无强依赖」两个待办小节本身的条目增删。**这次 ROADMAP.md 更新本身必须单独 commit**（`git add openspec/changes/ROADMAP.md && git commit -m "docs(roadmap): remove <change-name>, archived"`，同样不自动 push）——这一步发生在 `yueban-spec-single-change-flow` 第四步的 commit 之后，不在那次 commit 范围内，如果不单独提交，这处改动会以未提交状态留在工作区，下一个 change 走 `yueban-spec-single-change-flow` 前置检查的 `git status --short`（要求工作区干净）就会被它挡住。更新+提交完 `ROADMAP.md` 后直接继续处理下一个 pending change，不用等用户确认——这是本 skill 存在的意义（用户已经在触发本 skill 时表达了"连续做完"的意图）。**但每完成一个 change 后，都暂停一下向用户汇报一次进度**（刚处理完的 change 名、commit hash、接下来还剩几个）再继续——这不是要用户批准继续（那会违背本 skill"连续做完"的存在意义），只是不能让好几个小时、好几次未经人看过 diff 的本地提交全程零可见性，给用户一个能随时叫停的检查点。如果某个 change 因为 Open Questions 未定案而卡住，向用户提问，拿到答复前不要跳过它去做后面的（除非用户明确说"先跳过这个，做完其它的再回来"）。**子流程本身没能走完全程**（第一步校验反复撞到轮次上限仍有未解决的 blocker、或第二步 `openspec-apply-change` 遇到阻塞而中止）同样要暂停、向用户说明失败详情——不能把这个 change 标记为已完成写入 `ROADMAP.md`，也不能跳到下一个 change 去，处理方式和"Open Questions 未定案"一致：等用户拍板（跳过/调整方案/终止本 skill）后再继续。
7. `ROADMAP.md` 的「有依赖关系」和「无强依赖」两个小节都清空后，本 skill 结束。

## 收尾

`ROADMAP.md` 清空后，向用户汇报：共处理了多少个 change（列名字+各自的 commit hash，并提醒这些 commit 都还只在本地、尚未推送，是否推送由用户自己决定）。全程如果被某个 change 的 Open Question 卡住过，也一并说明当时是怎么决定的。

## 已知坑

参见 [`yueban-spec-single-change-flow`](../yueban-spec-single-change-flow/SKILL.md) 的"已知坑"一节。额外补充两条本 skill 自己层面的坑：

- **"无强依赖"不等于"能安全并行"**：ROADMAP 判定无执行顺序依赖的两个 change，仍可能改同一个共享文件的不同区块（比如同一个前端菜单数组）。默认串行能完全规避这个问题；如果为了速度改成并行，必须先做文件级重叠核实，不能只看 ROADMAP 的依赖标注。
- **批次并行计划会被执行中新增的文件打破**：即使事前用静态重叠分析规划好了"互不冲突的批次"，某个 change 实际执行中新建的文件也可能被同批次另一个 change 引用到，产生计划外的依赖。这类情况要靠每个 change 自己的门禁验证（真实 build/test/e2e）兜底探测，不能完全信任事前的批次划分。
