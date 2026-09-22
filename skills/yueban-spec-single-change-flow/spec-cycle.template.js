// Template for the yueban-spec-single-change-flow skill's step-1 spec-review→fix loop.
// This checked-in file is the only authoritative copy — do not rely on any leftover
// scratchpad/tmp copy from a previous session; those are session-local and won't exist
// in a fresh session or on another machine.
//
// This loop runs BEFORE implementation (openspec-apply-change is a separate step-2, invoked
// by the orchestrating session after this Workflow returns). It only audits whether
// proposal.md/design.md/tasks.md/specs/**/*.md are internally consistent and still match the
// current codebase's structure — it does NOT implement anything and does NOT touch
// backend/ or frontend/ code. The fix agent below is restricted to editing those four
// markdown artifact types only.
//
// HOW TO USE: Read this file's text, replace both occurrences of CHANGE_NAME_PLACEHOLDER
// (meta.name and `const CHANGE = '...'`) with the literal change name in your own context,
// then pass the substituted text directly via Workflow's `script` parameter:
//   Workflow({ script: '<substituted file text>' })
// Do NOT use `scriptPath` pointing at this template file directly (the placeholders won't
// be substituted) and do NOT write the substituted text out to a new file first (unnecessary
// — Workflow's own script param takes the text inline; the tool persists it internally for
// resume purposes, which is its own implementation detail, not something this skill manages).
//
// Do NOT try to parameterize CHANGE via Workflow's `args` at runtime instead of substituting
// it into the script text. Substituting the literal directly into the script text keeps this
// script fully self-contained — replaying the exact same text on a different session/machine
// reproduces the exact same behavior with no dependency on how `args` gets threaded through.
// (An earlier version of this comment claimed `args` intermittently arrived as the literal
// string "undefined" due to a "template-substitution bug" — per Workflow's actual semantics,
// `args` is exposed to the script as a plain JS value, not interpolated into the script text,
// so that specific mechanism doesn't hold up and was never independently confirmed. The
// literal-substitution approach is kept anyway because self-containment is reason enough; if
// a real `args` issue is ever confirmed, replace this note with the verified cause.)

export const meta = {
  name: 'spec-cycle-CHANGE_NAME_PLACEHOLDER',
  description: '单个 openspec change 在实施前的 spec 文档校验循环：round=[并行只读多角度评审 proposal/design/tasks/specs]→[单一顺序修复agent，只改这几份文档]，收敛即停（最少1轮）最多5轮。不实施代码、不跑构建/测试命令——实施是本模板之外的独立步骤（openspec-apply-change）。',
  // 必须和运行时 phase(`Round${round}`) 实际用到的标题逐一对应（Workflow 要求精确匹配才能分组），
  // 不能只写一个笼统的 'Round' —— MAX_ROUNDS 是编译期已知的常量（见下方），这里按它的上限把
  // 每一轮可能用到的标题都列全；循环提前收敛、后面的轮次没跑到时，对应的 phase 自然不会被用到。
  phases: [
    { title: 'Round1' },
    { title: 'Round2' },
    { title: 'Round3' },
    { title: 'Round4' },
    { title: 'Round5' },
  ],
}

// ↓↓↓ 替换成实际的 change 名（openspec/changes/<CHANGE>/），例如 'fix-admin-sidebar-overflow-indicator'
const CHANGE = 'CHANGE_NAME_PLACEHOLDER'

// 如果某个任务组明确不属于本轮自动修复范围（比如用户已经说了"这部分先不做"），
// 在这里写一句话说明，会被拼进每个 review/fix agent 的 prompt 里。平时留空字符串。
const SKIP_NOTE = ''

// 已拍板：MIN_ROUNDS=1（一轮 0 问题就立刻停，不强制凑轮次）、MAX_ROUNDS=5（硬上限）。
// 不要不问用户就改这两个数字——如果用户当次给出不同要求，以当次为准。
// 改 MAX_ROUNDS 时必须同步改上面 meta.phases 里的 Round1..RoundN 列表，
// 让它跟这里的上限保持一致（meta 是纯字面量，不能引用这个常量）。
const MIN_ROUNDS = 1
const MAX_ROUNDS = 5

const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    issues: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major', 'minor'] },
          description: { type: 'string' },
          location: { type: 'string' },
        },
        required: ['severity', 'description'],
      },
    },
    summary: { type: 'string' },
  },
  required: ['issues', 'summary'],
}

const VALIDATE_SCHEMA = {
  type: 'object',
  properties: {
    passed: { type: 'boolean' },
    output: { type: 'string' },
  },
  required: ['passed', 'output'],
}

const roundLog = []
let stoppedEarly = false

for (let round = 1; round <= MAX_ROUNDS; round++) {
  const phaseTitle = `Round${round}`
  phase(phaseTitle)
  log(`[${CHANGE}] round ${round} 开始（spec 文档校验，实施尚未开始）`)

  const skipClause = SKIP_NOTE ? `以下任务组不属于本次自动修复范围，只报告现状不要执行：${SKIP_NOTE}。` : ''

  const reviews = await parallel([
    () => agent(
      `阅读 openspec/changes/${CHANGE}/ 下的 proposal.md、design.md、tasks.md、specs/**/*.md，以及 openspec/config.yaml 的 rules。这是实施之前的 spec 文档审查，此时代码大概率还没实施，检查两类问题：` +
      `1) 文档间是否自洽：design.md 里的每条 Decision 是否都体现在 tasks.md 的具体任务里；tasks.md 是否覆盖了 proposal.md 的 Capabilities/Impact 段落承诺的全部范围（有没有承诺了但没拆成任务的遗漏，或任务里做了但 proposal 没提及的范围蔓延）；specs/**/*.md 的验收标准是否和 proposal.md/design.md 一致。` +
      `2) proposal.md/design.md/specs/**/*.md 是否满足 openspec/config.yaml 里 rules.proposal/rules.design/rules.specs 下逐条列出的要求——以 config.yaml 当前实际内容为准，不要凭记忆或过往经验判断规则是什么，它可能已经被项目维护者增删。tasks.md 对 config.yaml 的合规检查由另一个角度（task-executability）负责，这里只管 proposal/design/specs 三类文档，不要重复检查 tasks.md。` +
      `每条发现记为一条 issue，说明具体是哪份文档、哪个位置的问题。${skipClause}严格只读，不要修改任何文件。`,
      { label: `r${round}-doc-consistency`, phase: phaseTitle, schema: REVIEW_SCHEMA }
    ),
    () => agent(
      `阅读 openspec/changes/${CHANGE}/ 下的 design.md、proposal.md。核对这两份文档里对当前代码库的假设（文件路径、页面/接口数量、依赖的其他 change 是否已落地、数据结构现状）是否还成立——` +
      `要去读实际代码库核实，不是拿文档和文档互相比对。这个 change 立项可能是在依赖的上游 change 落地之前写的，现在代码现状可能已经变化（比如某个前置 change 已经归档、某个文件路径已经改变、页面/接口数量已经不对）。` +
      `每条发现记为一条 issue（severity=blocker 如果假设已经明显过期影响任务可执行性，否则 major/minor），说明具体哪个假设、现在实际是什么。${skipClause}严格只读，不要修改任何文件。`,
      { label: `r${round}-design-premise`, phase: phaseTitle, schema: REVIEW_SCHEMA }
    ),
    () => agent(
      `阅读 openspec/changes/${CHANGE}/tasks.md，以及 openspec/config.yaml 的 rules。检查：` +
      `1) tasks.md 里每条任务描述是否足够具体、可以被后续的实施 agent 直接执行而不需要额外澄清（模糊的任务会导致实施阶段卡住反复追问，记为一条 issue）；` +
      `2) 是否满足 openspec/config.yaml 里 rules.tasks 下逐条列出的要求——以 config.yaml 当前实际内容为准，不要凭记忆或过往经验判断规则是什么，它可能已经被项目维护者增删。` +
      `每条发现记为一条 issue。${skipClause}严格只读，不要修改任何文件。`,
      { label: `r${round}-task-executability`, phase: phaseTitle, schema: REVIEW_SCHEMA }
    ),
    () => agent(
      `阅读 openspec/changes/${CHANGE}/tasks.md。检查里面的验证类任务是否只写了"跑现有测试不报错""跑一遍验证套件"这类泛化描述，还是针对本次新增/变更的具体行为写了有针对性的新断言（比如新增字段在页面上的展示校验、新增交互路径的具体检查点、新增接口的边界条件断言）。` +
      `泛化描述即使技术上可执行，也发现不了本次改动引入的回归，记为一条 issue 要求补充具体断言；已有断言若已经覆盖到位则不需要挑刺。${skipClause}严格只读，不要修改任何文件。`,
      { label: `r${round}-test-assertion-sufficiency`, phase: phaseTitle, schema: REVIEW_SCHEMA }
    ),
  ])

  // parallel() 里单个 agent 因 API 错误重试耗尽会 resolve 成 null（见 .filter(Boolean)），
  // 不会让整轮作废——其余 agent 的结果仍然有效。如果同一个 change 反复在同一个角度上失败，
  // 在收尾报告里向用户说明，不要无限重试。
  const issues = reviews.filter(Boolean).flatMap((r) => r.issues || [])
  log(`[${CHANGE}] round ${round} 发现 ${issues.length} 个问题`)

  let validateResult = null

  if (issues.length > 0) {
    const issueText = issues
      .map((it, i) => `${i + 1}. [${it.severity}] ${it.description}${it.location ? ` (${it.location})` : ''}`)
      .join('\n')
    await agent(
      `openspec/changes/${CHANGE}/ 的 spec 文档校验发现以下问题，请按顺序逐条修复（这是本轮唯一的修改 agent，不会有其他 agent 并行改动这批文件）：\n${issueText}\n\n` +
      `**只允许编辑 openspec/changes/${CHANGE}/ 下的 proposal.md、design.md、tasks.md、specs/**/*.md 这几份文档**，把过期的设计前提、不自洽的描述、不够具体的任务拆分改到位——这是实施之前的文档校验，绝不修改 backend/ 或 frontend/ 下的任何代码，也不需要新增/修改任何测试文件。${skipClause}` +
      `修复完成后不需要跑 go build/npx tsc 这类命令（这一步不产出代码改动，没有可编译的内容）；完成后用 \`git status\` 确认改动只涉及上述几份 openspec 文档，没有意外碰到代码文件。`,
      { label: `r${round}-fix`, phase: phaseTitle }
    )

    // 修复 agent 只做语义/内容层面的判断，不保证没把 openspec CLI 要求的格式（必需 section、
    // MUST/WHEN/THEN 关键字等）改坏。openspec validate 是确定性的格式检查，跑一次成本很低，
    // 在这里做能比等到第三步（实施完之后）才发现格式问题更早拦住，避免带着坏格式去实施。
    validateResult = await agent(
      `在仓库根目录运行 \`openspec validate ${CHANGE}\` 命令，报告是否通过（passed）以及完整的命令输出（output，包含 stdout 和 stderr）。只运行这一个命令并如实报告结果，不要自行修改任何文件。`,
      { label: `r${round}-validate`, phase: phaseTitle, schema: VALIDATE_SCHEMA }
    )

    if (validateResult && !validateResult.passed) {
      log(`[${CHANGE}] round ${round} openspec validate 未通过，尝试针对性修复一次`)
      await agent(
        `openspec/changes/${CHANGE}/ 跑 \`openspec validate ${CHANGE}\` 未通过，报错如下：\n${validateResult.output}\n\n` +
        `请只针对这个报错修复格式问题（比如缺失的必需 section、MUST/WHEN/THEN 关键字丢失等）——` +
        `**只允许编辑 proposal.md、design.md、tasks.md、specs/**/*.md**，不改变已修复的内容语义，只修格式。修完后重新运行 \`openspec validate ${CHANGE}\` 确认通过，并在完成后报告最终是否通过。`,
        { label: `r${round}-validate-fix`, phase: phaseTitle }
      )
      validateResult = await agent(
        `在仓库根目录再次运行 \`openspec validate ${CHANGE}\` 命令，报告是否通过（passed）以及完整的命令输出（output）。只运行这一个命令，不要修改任何文件。`,
        { label: `r${round}-validate-recheck`, phase: phaseTitle, schema: VALIDATE_SCHEMA }
      )
    }
  }

  roundLog.push({
    round,
    issueCount: issues.length,
    issues,
    validatePassed: validateResult ? validateResult.passed : null,
    validateOutput: validateResult && !validateResult.passed ? validateResult.output : null,
  })

  if (issues.length === 0 && round >= MIN_ROUNDS) {
    stoppedEarly = round < MAX_ROUNDS
    log(`[${CHANGE}] round ${round} 零问题且已达最少轮次，提前收敛结束校验循环`)
    break
  }
}

const finalRound = roundLog.length > 0 ? roundLog[roundLog.length - 1] : null
const fullyConverged = finalRound ? finalRound.issueCount === 0 : true
const unresolvedBlockers = finalRound ? finalRound.issues.filter((it) => it.severity === 'blocker') : []
// validate 只在该轮 issueCount > 0 时才会运行（见上方循环里的 `if (issues.length > 0)`）；
// issueCount === 0 的收敛轮次里 validatePassed 本来就是 null，因为根本没有 validate 可跑，
// 这不是失败，不能计入 unresolvedValidateFailure（否则最常见的"零问题收敛"成功路径会被
// 每次误判成未解决）。只有 issueCount > 0 却仍拿不到确定的 `true` 时才算未解决——这既覆盖了
// "复检后仍未通过"（validatePassed === false，文档原有语义），也覆盖了"validate 这个 agent
// 调用本身失败、resolve 成了 null"（见 ../SKILL.md 的"已知坑"一节）：后者此前会被 `=== false`
// 的写法误判成"没有失败"，因为 null !== false，但它同样是"从未真正确认通过"，必须一并当成未解决。
const unresolvedValidateFailure = !!(finalRound && finalRound.issueCount > 0 && finalRound.validatePassed !== true)

return {
  change: CHANGE,
  roundLog,
  stoppedEarly,
  totalRounds: roundLog.length,
  fullyConverged,
  // 最后一轮发现的问题。若 fullyConverged 为 false，修复 agent 已经针对这些跑过一遍，但没有
  // 再跑一轮 review 确认修复生效——视为"相信已修，未独立复核"，不是"仍然未处理"。
  lastRoundIssues: finalRound ? finalRound.issues : [],
  // 撞到 MAX_ROUNDS 时如果还有 blocker 级别的未复核问题，调用方（SKILL.md 第一步）应该
  // 停下来向用户说明，而不是直接进入第二步实施——blocker 级问题通常意味着 tasks.md 的任务
  // 拆分本身不可执行，带着它去实施大概率会卡住或做错方向。
  unresolvedBlockers,
  unresolvedValidateFailure,
}
