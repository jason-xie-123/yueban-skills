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
// Review pattern: round 1 is always a FULL review (all 4 dimensions in parallel). Middle
// rounds are INCREMENTAL (a single scoped agent that only verifies the previous round's
// fix and checks for regressions it introduced — cheap). Whenever a round (full or
// incremental) finds zero blocker/major issues, the loop either exits (if that round was
// full — a full review is the only thing allowed to confirm convergence) or promotes the
// NEXT round to full so convergence gets confirmed by a full pass before exiting. The last
// round is always forced full if MAX_ROUNDS is hit, so the final report always reflects a
// full audit. minor-severity issues are never fixed mid-loop — they're accumulated and
// fixed once, in a single batch pass, only after the loop actually converges.
//
// Product/technical tradeoff disagreements (not factual doc errors) are adjudicated by the
// fix agent using a fixed priority order (PRD text > openspec/config.yaml rules > existing
// codebase pattern > demo/prototype) and recorded in design.md's "Decision Record" section.
// Once recorded, later rounds must not re-litigate the same decision unless they can cite
// new PRD/config.yaml text — this is what stopped a real run from flip-flopping across
// rounds on the same product question.
//
// Round 1 also kicks off a one-time baseline probe (in parallel with the review agents):
// run the project's standard build+test command and report which failures already exist
// BEFORE this change's implementation starts. This used to only surface after step 2 was
// well underway, costing a stop-and-fix detour; now it's ready by the time step 1 finishes,
// since step 1 takes tens of minutes anyway and the baseline run fits inside that window.
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

export const meta = {
  name: 'spec-cycle-CHANGE_NAME_PLACEHOLDER',
  description: '单个 openspec change 在实施前的 spec 文档校验循环：round 1 全量、中间轮次增量（只核实上一轮的修复+检查有没有引入新问题）、收敛前最后一轮再全量把关；停止条件是 blocker/major 清零（不要求零问题），minor 级问题收敛后统一修一次；round 1 顺带并行跑一次基线探测（改动前代码库本就存在哪些测试失败）；产品/技术取舍类分歧由修复 agent 按固定优先级裁决并记入 design.md 的决策记录，之后轮次不得无新证据翻案。不实施代码、不跑构建/测试命令（基线探测除外，那只读不改）——实施是本模板之外的独立步骤（openspec-apply-change）。',
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

// 已拍板：MIN_ROUNDS=1（round 1 若已经是全量且 blocker/major=0，立刻停，不强制凑轮次）、
// MAX_ROUNDS=5（硬上限，命中时最后一轮强制全量）。不要不问用户就改这两个数字——如果用户
// 当次给出不同要求，以当次为准。改 MAX_ROUNDS 时必须同步改上面 meta.phases 里的
// Round1..RoundN 列表，让它跟这里的上限保持一致（meta 是纯字面量，不能引用这个常量）。
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

const BASELINE_SCHEMA = {
  type: 'object',
  properties: {
    passed: { type: 'boolean' },
    failingTests: { type: 'array', items: { type: 'string' } },
    output: { type: 'string' },
  },
  required: ['passed', 'failingTests', 'output'],
}

// 产品/技术取舍类分歧（不是"文档写错了"这种事实性错误，而是"要不要做某个功能点""某个字段
// 要不要展示"这类没有唯一正确答案、需要权衡的问题）的裁决规则，分别喂给评审 agent 和修复 agent。
const DECISION_NOTE_FOR_REVIEWERS =
  '如果你发现的问题本质上是产品/技术取舍类分歧（不是"文档写错了""任务描述不完整"这类事实性错误）：' +
  '先看 design.md 是否已经有一个『Decision Record』小节，是否已经就同一件事写过裁决。' +
  '如果已经裁决过，默认不要重复提出——除非你能引用到 proposal.md 的 PRD 原文或 openspec/config.yaml 的 ' +
  'rules 原文这类新证据（不是换一种措辞重新表达同一个偏好），才可以重新标记为 issue，并在 description 里 ' +
  '写清楚引用的新证据具体是什么、出自哪份文档的哪句话。'

const DECISION_NOTE_FOR_FIX =
  '如果某条 issue 属于产品/技术取舍类分歧（不是单纯的文字/格式修正），按固定顺序独立裁决，不要停下来问用户：' +
  '1) 先看 proposal.md 里 PRD/需求原文是否有明确说法；2) 再看 openspec/config.yaml 的 rules 是否有强制约定；' +
  '3) 再看代码库现有实现的既定模式；4) 最后才参考 demo/原型。裁决完成后，把结论和依据（引用的是上面哪一条、' +
  '具体是什么内容）追加进 design.md 的『Decision Record』小节（没有这个小节就新建一个二级标题 `## Decision ' +
  'Record`，每条记录格式：`- <一句话描述分歧> — 裁决：<结论>；依据：<引用的 PRD/config.yaml 原文或现状代码>`）。' +
  '裁决之后同一件事默认不再改判，除非后续拿到新证据。'

function issuesToText(list) {
  return list
    .map((it, i) => `${i + 1}. [${it.severity}] ${it.description}${it.location ? ` (${it.location})` : ''}`)
    .join('\n')
}

function skipClauseFor() {
  return SKIP_NOTE ? `以下任务组不属于本次自动修复范围，只报告现状不要执行：${SKIP_NOTE}。` : ''
}

const roundLog = []
let stoppedEarly = false
let promoteNextToFull = false
const pendingMinors = []
let baseline = null

for (let round = 1; round <= MAX_ROUNDS; round++) {
  const phaseTitle = `Round${round}`
  phase(phaseTitle)
  const isFull = round === 1 || round === MAX_ROUNDS || promoteNextToFull
  promoteNextToFull = false
  log(`[${CHANGE}] round ${round} 开始（${isFull ? '全量' : '增量'}审查，spec 文档校验，实施尚未开始）`)

  const skipClause = skipClauseFor()
  let issues

  if (isFull) {
    const tasks = [
      () => agent(
        `阅读 openspec/changes/${CHANGE}/ 下的 proposal.md、design.md、tasks.md、specs/**/*.md，以及 openspec/config.yaml 的 rules。这是实施之前的 spec 文档审查，此时代码大概率还没实施，检查两类问题：` +
        `1) 文档间是否自洽：design.md 里的每条 Decision（含『Decision Record』小节里的裁决记录）是否都体现在 tasks.md 的具体任务里；tasks.md 是否覆盖了 proposal.md 的 Capabilities/Impact 段落承诺的全部范围（有没有承诺了但没拆成任务的遗漏，或任务里做了但 proposal 没提及的范围蔓延）；specs/**/*.md 的验收标准是否和 proposal.md/design.md 一致。` +
        `2) proposal.md/design.md/specs/**/*.md 是否满足 openspec/config.yaml 里 rules.proposal/rules.design/rules.specs 下逐条列出的要求——以 config.yaml 当前实际内容为准，不要凭记忆或过往经验判断规则是什么，它可能已经被项目维护者增删。tasks.md 对 config.yaml 的合规检查由另一个角度（task-executability）负责，这里只管 proposal/design/specs 三类文档，不要重复检查 tasks.md。` +
        `每条发现记为一条 issue，说明具体是哪份文档、哪个位置的问题。${DECISION_NOTE_FOR_REVIEWERS}${skipClause}严格只读，不要修改任何文件。`,
        { label: `r${round}-doc-consistency`, phase: phaseTitle, schema: REVIEW_SCHEMA }
      ),
      () => agent(
        `阅读 openspec/changes/${CHANGE}/ 下的 design.md、proposal.md。核对这两份文档里对当前代码库的假设（文件路径、页面/接口数量、依赖的其他 change 是否已落地、数据结构现状）是否还成立——` +
        `要去读实际代码库核实，不是拿文档和文档互相比对。这个 change 立项可能是在依赖的上游 change 落地之前写的，现在代码现状可能已经变化（比如某个前置 change 已经归档、某个文件路径已经改变、页面/接口数量已经不对）。` +
        `每条发现记为一条 issue（severity=blocker 如果假设已经明显过期影响任务可执行性，否则 major/minor），说明具体哪个假设、现在实际是什么。${DECISION_NOTE_FOR_REVIEWERS}${skipClause}严格只读，不要修改任何文件。`,
        { label: `r${round}-design-premise`, phase: phaseTitle, schema: REVIEW_SCHEMA }
      ),
      () => agent(
        `阅读 openspec/changes/${CHANGE}/tasks.md，以及 openspec/config.yaml 的 rules。检查：` +
        `1) tasks.md 里每条任务描述是否足够具体、可以被后续的实施 agent 直接执行而不需要额外澄清（模糊的任务会导致实施阶段卡住反复追问，记为一条 issue）；` +
        `2) 是否满足 openspec/config.yaml 里 rules.tasks 下逐条列出的要求——以 config.yaml 当前实际内容为准，不要凭记忆或过往经验判断规则是什么，它可能已经被项目维护者增删。` +
        `每条发现记为一条 issue。${DECISION_NOTE_FOR_REVIEWERS}${skipClause}严格只读，不要修改任何文件。`,
        { label: `r${round}-task-executability`, phase: phaseTitle, schema: REVIEW_SCHEMA }
      ),
      () => agent(
        `阅读 openspec/changes/${CHANGE}/tasks.md。检查里面的验证类任务是否只写了"跑现有测试不报错""跑一遍验证套件"这类泛化描述，还是针对本次新增/变更的具体行为写了有针对性的新断言（比如新增字段在页面上的展示校验、新增交互路径的具体检查点、新增接口的边界条件断言）。` +
        `泛化描述即使技术上可执行，也发现不了本次改动引入的回归，记为一条 issue 要求补充具体断言；已有断言若已经覆盖到位则不需要挑刺。` +
        `**只检查"有没有针对本次新增/变更行为的断言"这一件事，不要求断言穷尽所有 edge case、也不要求写得比现在更细**——只要已经存在断言覆盖到本次新增/变更的具体行为就算通过，不能以"可以写得更细/更全"为理由反复提出新的 issue（这是真实观察到的问题：断言颗粒度要求没有上限，导致 tasks.md 越写越长、实施阶段被迫写出大量非必要的用例）。${DECISION_NOTE_FOR_REVIEWERS}${skipClause}严格只读，不要修改任何文件。`,
        { label: `r${round}-test-assertion-sufficiency`, phase: phaseTitle, schema: REVIEW_SCHEMA }
      ),
    ]

    // round 1 的基线探测和 4 个文档评审角度并发跑，但故意不塞进同一个 parallel() 数组里靠数组
    // 位置去取结果——parallel() 的返回顺序理应和传入顺序一致，但用位置（比如 pop() 最后一个）
    // 去识别"哪个结果是基线"仍然是脆弱的隐式假设，一旦哪天顺序假设不成立就会把基线和评审结果
    // 互相污染。这里改成两个独立的 parallel() 调用，用 Promise.all 并发等待，用返回值本身的
    // 角色（reviewResults vs baselineResults）区分，不依赖数组位置。
    if (round === 1) {
      const baselineTask = () => agent(
        `在仓库根目录，找到并执行这个项目当前标准的完整验证命令（构建+测试，比如但不限于 \`go build ./... && go test ./...\`、\`npm run build && npm test\`、\`pytest\` 等——具体以项目实际的 package.json/Makefile/README/CI 配置为准，不要假设是某个特定技术栈）。` +
        `这是在 openspec/changes/${CHANGE}/ 这个 change 实施之前，先摸底代码库当前已经存在哪些失败（baseline），不要修改任何文件，也不要尝试修复看到的失败。` +
        `报告 passed（是否全部通过）、failingTests（失败的测试/构建步骤名称列表，尽量具体到用例名，没有失败则为空数组）、output（关键的命令输出/报错片段）。`,
        { label: 'baseline-probe', phase: phaseTitle, schema: BASELINE_SCHEMA }
      )
      const [reviewResults, baselineResults] = await Promise.all([parallel(tasks), parallel([baselineTask])])
      baseline = baselineResults[0]
      // parallel() 里单个 agent 因 API 错误重试耗尽会 resolve 成 null（见 .filter(Boolean)），
      // 不会让整轮作废——其余 agent 的结果仍然有效。如果同一个 change 反复在同一个角度上失败，
      // 在收尾报告里向用户说明，不要无限重试。
      issues = reviewResults.filter(Boolean).flatMap((r) => r.issues || [])
    } else {
      const reviewResults = await parallel(tasks)
      issues = reviewResults.filter(Boolean).flatMap((r) => r.issues || [])
    }
  } else {
    // 只把上一轮实际交给修复 agent 处理过的 blocker/major 列进"应该已经修好"的复核清单——
    // 上一轮的 minor 是按设计故意不修的（累积到收敛后统一批量处理），如果把它们也塞进这份
    // "应该已经处理过"的清单，等于给增量复核 agent 一个错误的前提，可能被它当成"声称修好但
    // 其实没修"从而误判严重程度升级。minor 不在这里提及不代表被忽略——它们仍然会被这轮的
    // 评审角度按需发现、记录，只是不会被要求"验证是否已修"。
    const prevRound = roundLog.length > 0 ? roundLog[roundLog.length - 1] : null
    const prevBlockerMajor = prevRound ? prevRound.issues.filter((it) => it.severity === 'blocker' || it.severity === 'major') : []
    const prevIssueText = issuesToText(prevBlockerMajor)
    const incrementalResult = await agent(
      `openspec/changes/${CHANGE}/ 上一轮 spec 文档校验发现了以下 blocker/major 级问题，上一轮的修复 agent 应该已经处理过（minor 级问题这一轮不用管，按设计会在循环收敛后统一批量修复，没有被遗漏，只是不在本轮验证范围内）：\n${prevIssueText}\n\n` +
      `这是一次增量复核，只做两件事，不要重新从头审查整份文档：` +
      `1) 针对上面每一条，读它涉及的具体位置（proposal.md/design.md/tasks.md/specs/**/*.md），确认修复是否真的到位；` +
      `2) 检查这次修复本身有没有在同一批被改动的文档里引入新的不自洽（比如改了一处但没同步改相关联的另一处、破坏了 openspec/config.yaml 的 rules 要求）。` +
      `未涉及、这轮没被改动过的部分不需要重新审查。每条发现记为一条 issue。${DECISION_NOTE_FOR_REVIEWERS}${skipClause}严格只读，不要修改任何文件。`,
      { label: `r${round}-incremental`, phase: phaseTitle, schema: REVIEW_SCHEMA }
    )
    if (!incrementalResult) {
      // 和上面并行全量审查里的 null-resolve 情况一样（API 重试耗尽），但增量复核只有唯一一个
      // agent，没有其他并行结果兜底——按 0 issue 处理会让本轮"误判为已收敛"，不过不是漏检：
      // 下一轮会被 promoteNextToFull 强制升级为全量重新核实，只是白白浪费了这一轮的增量复核。
      log(`[${CHANGE}] round ${round} 增量复核 agent 调用失败（resolve 成 null），本轮按 0 issue 处理，下一轮强制全量兜底`)
    }
    issues = incrementalResult ? incrementalResult.issues || [] : []
  }

  const blockerMajor = issues.filter((it) => it.severity === 'blocker' || it.severity === 'major')
  const minors = issues.filter((it) => it.severity === 'minor')
  pendingMinors.push(...minors)

  log(`[${CHANGE}] round ${round} 发现 ${issues.length} 个问题（blocker/major ${blockerMajor.length}，minor ${minors.length}——minor 本轮不修，留到收敛后统一处理一次）`)

  let validateResult = null

  if (blockerMajor.length > 0) {
    await agent(
      `openspec/changes/${CHANGE}/ 的 spec 文档校验发现以下 blocker/major 级问题，请按顺序逐条修复（这是本轮唯一的修改 agent，不会有其他 agent 并行改动这批文件；minor 级问题这一轮不处理，会在校验循环收敛后统一批量修复一次，不用管）：\n${issuesToText(blockerMajor)}\n\n` +
      `**只允许编辑 openspec/changes/${CHANGE}/ 下的 proposal.md、design.md、tasks.md、specs/**/*.md 这几份文档**，把过期的设计前提、不自洽的描述、不够具体的任务拆分改到位——这是实施之前的文档校验，绝不修改 backend/ 或 frontend/ 下的任何代码，也不需要新增/修改任何测试文件。${DECISION_NOTE_FOR_FIX}${skipClause}` +
      `修复完成后不需要跑 go build/npx tsc 这类命令（这一步不产出代码改动，没有可编译的内容）；完成后用 \`git status\` 确认改动只涉及上述几份 openspec 文档，没有意外碰到代码文件。`,
      { label: `r${round}-fix`, phase: phaseTitle }
    )

    // 修复 agent 只做语义/内容层面的判断，不保证没把 openspec CLI 要求的格式（必需 section、
    // MUST/WHEN/THEN 关键字等）改坏。openspec validate 是确定性的格式检查，跑一次成本很低，
    // 在这里做能比等到第四步（实施完之后）才发现格式问题更早拦住，避免带着坏格式去实施。
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
    isFull,
    issueCount: issues.length,
    blockerMajorCount: blockerMajor.length,
    minorCount: minors.length,
    issues,
    validatePassed: validateResult ? validateResult.passed : null,
    validateOutput: validateResult && !validateResult.passed ? validateResult.output : null,
  })

  if (blockerMajor.length === 0) {
    if (isFull && round >= MIN_ROUNDS) {
      stoppedEarly = round < MAX_ROUNDS
      log(`[${CHANGE}] round ${round}（全量）blocker/major 清零，收敛结束校验循环`)
      break
    }
    if (!isFull) {
      promoteNextToFull = true
      log(`[${CHANGE}] round ${round}（增量）blocker/major 清零，下一轮升级为全量把关以确认`)
    }
    // isFull 但 round < MIN_ROUNDS 是 MIN_ROUNDS 被改成 >1 时的退化情况（默认不会发生）：
    // 不满足最少轮次，落到下一轮继续（下一轮按 isFull 判定式重新计算，通常会是增量）。
  }
}

const finalRound = roundLog.length > 0 ? roundLog[roundLog.length - 1] : null
const fullyConverged = finalRound ? finalRound.blockerMajorCount === 0 : true
const unresolvedBlockers = finalRound ? finalRound.issues.filter((it) => it.severity === 'blocker') : []
// validate 只在该轮 blockerMajorCount > 0 时才会运行（见上方循环里的 `if (blockerMajor.length > 0)`）；
// blockerMajorCount === 0 的收敛轮次里 validatePassed 本来就是 null，因为根本没有 validate 可跑，
// 这不是失败，不能计入 unresolvedValidateFailure（否则最常见的"收敛"成功路径会被每次误判成未解决）。
// 只有 blockerMajorCount > 0 却仍拿不到确定的 `true` 时才算未解决——这既覆盖了"复检后仍未通过"
//（validatePassed === false，文档原有语义），也覆盖了"validate 这个 agent 调用本身失败、resolve 成了 null"
//（见 ../SKILL.md 的"已知坑"一节）：后者若写成 `=== false` 会被误判成"没有失败"，因为 null !== false，
// 但它同样是"从未真正确认通过"，必须一并当成未解决。
let unresolvedValidateFailure = !!(finalRound && finalRound.blockerMajorCount > 0 && finalRound.validatePassed !== true)

// minor 级问题全程被跳过修复、只累积；只有循环真正收敛（blocker/major 清零）才在这里统一修一次，
// 不再单独触发一轮 review 去复核这次修复——这是收尾式的措辞/细节修正，信任修复结果。
// 如果撞了 MAX_ROUNDS 仍有未解决的 blocker/major，minor 不处理，交给调用方先解决 blocker 再说。
let pendingMinorsFixed = null
if (fullyConverged && pendingMinors.length > 0) {
  const minorFixPhase = finalRound ? `Round${finalRound.round}` : 'Round1'
  phase(minorFixPhase)
  log(`[${CHANGE}] 校验循环已收敛，统一修复 ${pendingMinors.length} 个累积的 minor 级问题`)
  await agent(
    `openspec/changes/${CHANGE}/ 的 spec 文档校验过程中，以下是尚未修复的 minor 级别问题（措辞/细节类问题，此前每一轮都特意没有单独处理，避免为了这类问题反复起轮次；现在校验循环已经收敛，统一修一次）：\n${issuesToText(pendingMinors)}\n\n` +
    `**只允许编辑 openspec/changes/${CHANGE}/ 下的 proposal.md、design.md、tasks.md、specs/**/*.md**，修完后不需要跑 go build/npx tsc 这类命令。${skipClauseFor()}`,
    { label: 'minor-batch-fix', phase: minorFixPhase }
  )
  let minorValidate = await agent(
    `在仓库根目录运行 \`openspec validate ${CHANGE}\` 命令，报告是否通过（passed）以及完整的命令输出（output）。只运行这一个命令，不要修改任何文件。`,
    { label: 'minor-batch-validate', phase: minorFixPhase, schema: VALIDATE_SCHEMA }
  )

  // minor 批量修复和 blocker/major 修复一样，只是语义/措辞层面的改动，同样不保证没把 openspec
  // CLI 要求的格式改坏——按和 blocker/major 修复路径一致的方式，跑一次针对性修复+复检（只修
  // 一次，不无限重试）；如果最终仍未通过，并入 unresolvedValidateFailure，不能让它在这里悄悄
  // 消失——不然调用方（SKILL.md 第二步的前置检查）永远不会知道收尾这一步把格式改坏了。
  if (minorValidate && !minorValidate.passed) {
    log(`[${CHANGE}] minor 批量修复后 openspec validate 未通过，尝试针对性修复一次`)
    await agent(
      `openspec/changes/${CHANGE}/ 跑 \`openspec validate ${CHANGE}\` 未通过，报错如下：\n${minorValidate.output}\n\n` +
      `请只针对这个报错修复格式问题（比如缺失的必需 section、MUST/WHEN/THEN 关键字丢失等）——` +
      `**只允许编辑 proposal.md、design.md、tasks.md、specs/**/*.md**，不改变已修复的内容语义，只修格式。修完后重新运行 \`openspec validate ${CHANGE}\` 确认通过，并在完成后报告最终是否通过。`,
      { label: 'minor-batch-validate-fix', phase: minorFixPhase }
    )
    minorValidate = await agent(
      `在仓库根目录再次运行 \`openspec validate ${CHANGE}\` 命令，报告是否通过（passed）以及完整的命令输出（output）。只运行这一个命令，不要修改任何文件。`,
      { label: 'minor-batch-validate-recheck', phase: minorFixPhase, schema: VALIDATE_SCHEMA }
    )
  }

  pendingMinorsFixed = {
    count: pendingMinors.length,
    validatePassed: minorValidate ? minorValidate.passed : null,
    validateOutput: minorValidate && !minorValidate.passed ? minorValidate.output : null,
  }
  if (!minorValidate || minorValidate.passed !== true) {
    // 同样覆盖"复检后仍未通过"和"validate 这个 agent 调用本身失败、resolve 成 null"两种情况，
    // 和上面 finalRound 那段判定 unresolvedValidateFailure 的逻辑保持一致。
    unresolvedValidateFailure = true
  }
}

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
  // round 1 并行跑的一次性基线探测结果：这次 change 实施之前，代码库本就存在哪些失败。
  // 调用方（SKILL.md 第二步/第三步/第五步）用它判断哪些失败是"既有的"，需要单独修复、单独提交，
  // 不能和本次 change 的实现混在同一个 commit 里，也不能误判成本次改动引入的新问题。
  baseline,
  // 收敛后批量修复 minor 问题的结果；未收敛（仍有 blocker/major）时保持 null，未处理 minor。
  pendingMinorsFixed,
}
