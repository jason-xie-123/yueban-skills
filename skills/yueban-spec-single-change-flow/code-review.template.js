// Template for the yueban-spec-single-change-flow skill's step-3 code review.
// This checked-in file is the only authoritative copy — do not rely on any leftover
// scratchpad/tmp copy from a previous session; those are session-local and won't exist
// in a fresh session or on another machine.
//
// This runs AFTER implementation (step 2, openspec-apply-change) and BEFORE validate/archive/
// commit (steps 4-5). It is deliberately a single pass that never blocks the flow: one
// parallel read-only review from 4 angles (plus one build+test run), one fix pass for
// blocker/major, one independent build+test run after the fix (with one targeted repair if the
// fix broke it), and then the caller commits no matter what. There is no second review of the
// fix — the independent build+test rerun is the only check on it (the fix agent's own claim
// about the build is never trusted), and fixes are recorded as "unreviewed". Whatever
// is left — unhandled issues, a failing build, a review angle that returned nothing — goes
// into `records`, which the caller copies verbatim into the commit message and ROADMAP.md for
// a human to look at later. The point of the skill is to keep a human out of the loop during
// long runs; a multi-round review→fix loop with stop conditions was tried and dropped for
// that reason.
//
// Scope: everything between REVIEW_BASE and the current working tree. The caller sets
// REVIEW_BASE to HEAD right before running this: in this flow the implementation stays
// uncommitted until step 5, so the scope is the uncommitted implementation plus any commit an
// agent sneaks in during this review (which therefore can't shrink the scope). Step 2's separate
// pre-existing-failure fix commits sit below REVIEW_BASE on purpose — they must stay out of this
// change's commit, so the fix agent must not touch them. The openspec/changes/<CHANGE>/ docs are
// reference material here, not review targets.
//
// Reviewers are told not to run build/test themselves: the build probe runs in parallel with
// them, and concurrent runs fight over ports/build dirs and produce fake failures.
//
// minor issues are recorded only, never fixed: with no second review pass, "small cleanups"
// are an unreviewed source of new bugs that isn't worth the risk.
//
// Records are built by this script from the reviewers' own issue text and the fix agent's
// per-issue status, so the traceable record is produced deterministically instead of being
// paraphrased by a model. Every record is a single line (newlines collapsed, long text
// truncated) so it can be appended to ROADMAP.md's one-line-per-entry logs as-is.
//
// HOW TO USE: Read this file's text, replace every occurrence of CHANGE_NAME_PLACEHOLDER
// (meta.name and `const CHANGE = '...'`) with the literal change name and REVIEW_BASE_PLACEHOLDER
// with the full SHA of HEAD taken right before running this (see SKILL.md step 3), fill BASELINE_NOTE from step 1's
// `baseline` result (see the comment on it below), then pass the substituted text directly via
// Workflow's `script` parameter — same rules as spec-cycle.template.js (no `scriptPath` at this
// template, no writing the substituted copy to a new file first, no `args`).

export const meta = {
  name: 'code-review-CHANGE_NAME_PLACEHOLDER',
  description: '单个 openspec change 实施完成后、提交之前的一次性代码 review：并行跑 4 个只读评审角度（正确性、spec 符合度、安全与健壮性、测试质量）和一次构建+测试；一个修复 agent 修一次 blocker/major 并逐条报告处理结果；修完由独立 agent 再跑一次构建+测试（修坏了给一次针对性修复），不再做第二轮 review。不管结果如何都不阻塞，剩下的问题由脚本生成留痕文本交给调用方写进 commit message 和 ROADMAP.md。minor 只记录不修。不 commit，不改 proposal/design/specs 文档。',
  phases: [{ title: 'Review' }, { title: 'Fix' }],
}

// ↓↓↓ 替换成实际的 change 名（openspec/changes/<CHANGE>/）
const CHANGE = 'CHANGE_NAME_PLACEHOLDER'

// ↓↓↓ 替换成跑这个 Workflow 之前 `git rev-parse HEAD` 的完整 SHA（见 SKILL.md 第三步）。审查范围 = 它到当前工作区的全部改动。
const REVIEW_BASE = 'REVIEW_BASE_PLACEHOLDER'

// 如果某个任务组明确不属于本次范围（比如用户已经说了"这部分先不做"），在这里写一句话说明，
// 会被拼进每个 review/fix agent 的 prompt 里。平时留空字符串。
const SKIP_NOTE = ''

// 用第一步 Workflow 返回的 baseline 填：列出 baseline.failingTests 里第二步结束时仍然存在的既有失败
// （第二步已经单独修复并提交掉的就不用列了），一句话即可，例如 'TestFoo、TestBar 在改动前就失败'。
// baseline 为 null（基线探测没拿到结果）时写 '基线探测未拿到结果，无法区分新旧失败'；没有既有失败时留空。
const BASELINE_NOTE = ''

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

const FIX_SCHEMA = {
  type: 'object',
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          issueIndex: { type: 'integer' },
          status: { type: 'string', enum: ['fixed', 'disputed', 'not_fixed'] },
          note: { type: 'string' },
        },
        required: ['issueIndex', 'status', 'note'],
      },
    },
  },
  required: ['results'],
}

const BUILD_SCHEMA = {
  type: 'object',
  properties: {
    passed: { type: 'boolean' },
    newFailures: { type: 'array', items: { type: 'string' } },
    output: { type: 'string' },
  },
  required: ['passed', 'newFailures', 'output'],
}

const SCOPE_NOTE =
  `审查范围：openspec change "${CHANGE}" 从基准提交 ${REVIEW_BASE} 到当前工作区的全部改动，不管有没有提交——` +
  `已跟踪文件看 \`git diff ${REVIEW_BASE}\`（包含基准之后的提交和未提交的改动，\`git log --oneline ${REVIEW_BASE}..HEAD\` 可以看到其间的提交），` +
  '未跟踪的新文件（`git status --short` 里 `??` 开头的）直接读全文。' +
  `openspec/changes/${CHANGE}/ 下的 proposal.md、design.md、tasks.md、specs/**/*.md 不是审查对象（第一步已经校验过），只作为判断"应该做成什么样"的对照依据来读。` +
  '不要只盯着 diff 片段：要读改动所在文件的上下文、被改函数的调用方，判断改动在真实调用路径上是否成立。'

const SEVERITY_NOTE =
  '严重程度按以下标准：blocker = 一定会出错且影响主路径/数据/安全（主流程逻辑错误、构建或测试失败、数据丢失或损坏、可被利用的安全漏洞、specs 里 MUST 级需求没实现、tasks.md 勾选了但实际没做）；' +
  'major = 现实中可触发的缺陷（边界条件、错误处理缺失导致用户可见的问题、并发/资源泄漏）、本次新增/变更的行为没有任何测试断言覆盖、明显违背 design.md 的决策；' +
  'minor = 不影响行为的问题（命名、重复代码、注释、和代码库既有写法不一致）。' +
  '每条 blocker/major 必须在 description 里写出具体触发场景（什么输入/状态下会出什么错）；给不出触发场景的猜测不要报，也不要把纯风格偏好升级成 major。'

// 所有会改文件的 agent 共用的护栏。
const FIX_GUARDRAILS =
  '不能靠删除/跳过/注释掉测试、放宽断言来"修复"问题（包括以"测试重复""断言冗余"为理由删改测试）。' +
  `不要修改 openspec/changes/${CHANGE}/ 下的 proposal.md、design.md、specs/**/*.md，不要把 tasks.md 里已勾选的任务改回未勾选，` +
  '不要 git commit/stash/checkout/reset。'

const BUILD_RUN_NOTE =
  '在仓库根目录执行项目当前标准的完整验证命令（构建+测试，以项目实际的 package.json/Makefile/README/CI 配置为准，不要假设是某个特定技术栈）'

const READ_ONLY = '严格只读，不要修改任何文件，也不要 git commit/stash/checkout/reset。'

// 评审 agent 只做静态审查：构建+测试由单独的 agent 同时在跑，并发再跑一遍会抢端口/构建目录，制造假失败。
const NO_BUILD_FOR_REVIEWERS = '不要运行构建、测试或任何会写构建目录/占端口的命令（另有 agent 正在同时跑构建+测试，并发运行会互相干扰），只读代码做静态审查。'

// 留痕里的每一条都必须是单行：压掉换行、截断过长内容，才能原样追加进 ROADMAP.md 一行一条的日志。
function oneLine(text, max = 300) {
  const flat = String(text == null ? '' : text).replace(/\s*\n\s*/g, ' ⏎ ').trim()
  return flat.length > max ? `${flat.slice(0, max)}…（已截断）` : flat
}

function baselineClause() {
  return BASELINE_NOTE
    ? `以下失败在本次改动之前就已存在，不算本次改动的问题，也不需要修：${BASELINE_NOTE}。`
    : ''
}

function skipClause() {
  return SKIP_NOTE ? `以下任务组不属于本次范围，不要评审或修改：${SKIP_NOTE}。` : ''
}

function issuesToText(list) {
  return list
    .map((it, i) => `${i + 1}. [${it.severity}] ${it.description}${it.location ? ` (${it.location})` : ''}`)
    .join('\n')
}

function issueRecordText(it) {
  return oneLine(`${it.description}${it.location ? `（${it.location}）` : ''}`)
}

function runBuild(label, phaseTitle) {
  return agent(
    `${BUILD_RUN_NOTE}。只运行并如实报告，不要修改任何文件，也不要尝试修复看到的失败。${baselineClause()}` +
    '报告 passed（除上述既有失败外是否全部通过）、newFailures（既有失败之外的失败名称列表）、output（关键输出/报错片段）。',
    { label, phase: phaseTitle, schema: BUILD_SCHEMA }
  )
}

function toBuildTest(result, missingNote) {
  return result ? { passed: result.passed, output: result.output } : { passed: null, output: missingNote }
}

const DIMENSIONS = [
  {
    key: 'correctness',
    name: '正确性',
    prompt: '从"正确性"角度审查代码：逻辑错误、边界条件（空值、空集合、越界、零/负数、超长输入）、错误处理（错误被吞掉、失败路径没回滚、返回值没检查）、并发与资源（竞态、锁、泄漏、未关闭的连接/文件）、' +
      '对既有调用方的破坏（改了签名/语义但没同步改调用方）。和代码库既有写法明显不一致、容易误用的地方记为 minor。',
  },
  {
    key: 'spec-conformance',
    name: 'spec 符合度',
    prompt: `从"spec 符合度"角度审查代码：读 openspec/changes/${CHANGE}/ 下的 tasks.md、specs/**/*.md、design.md，逐条核对——tasks.md 里每个勾选了的任务是否真的在代码里做了（勾选了没做记为 blocker）；` +
      'specs/**/*.md 里每条 Requirement/Scenario（MUST/WHEN/THEN）是否被实现满足；实现是否违背 design.md 的决策（含『Decision Record』小节）；有没有 proposal.md 没提到的范围蔓延。',
  },
  {
    key: 'security-robustness',
    name: '安全与健壮性',
    prompt: '从"安全与健壮性"角度审查代码：外部输入校验、注入（SQL/命令/路径/模板）、鉴权与越权、敏感信息（明文凭据、日志里泄漏敏感数据）、' +
      '数据库 migration 与数据变更的安全性（能否回滚、是否会锁表或破坏存量数据）、外部调用的超时与重试。本次改动没涉及的方面不需要硬凑问题。',
  },
  {
    key: 'test-quality',
    name: '测试质量',
    prompt: '从"测试质量"角度审查本次新增/修改的测试：是否真的断言了本次新增/变更的行为（而不是只跑通不断言、断言恒真、只断言 mock 自己的返回值）；' +
      '有没有被跳过/注释掉/删除的既有测试、被放宽的既有断言；tasks.md 里要求的验证类任务对应的测试是否真的存在。' +
      '**只检查"本次新增/变更的行为有没有被有效断言覆盖"，不要求穷尽所有 edge case**，不能以"可以写得更细/更全"为理由提出 issue。',
  },
]

// ---- Review：4 个只读角度 + 一次构建/测试，全部并发 ----
phase('Review')
log(`[${CHANGE}] 代码 review 开始（一次性：并行评审 → 修一次 → 不管结果如何都交给调用方提交）`)
const reviewCommon = `${SCOPE_NOTE}${SEVERITY_NOTE}${baselineClause()}${skipClause()}${NO_BUILD_FOR_REVIEWERS}${READ_ONLY}`
// 两个独立的 parallel() 区分结果角色，不依赖数组位置（和 spec-cycle.template.js 的 baseline 探测同一个做法）。
const [reviewResults, probeResults] = await Promise.all([
  parallel(DIMENSIONS.map((d) => () => agent(`${d.prompt}${reviewCommon}`, { label: `review-${d.key}`, phase: 'Review', schema: REVIEW_SCHEMA }))),
  parallel([() => runBuild('build-probe', 'Review')]),
])
// 单个评审 agent 因 API 重试耗尽会 resolve 成 null——该角度等于没审，记进留痕，不重试、不阻塞。
const missingDimensions = DIMENSIONS.filter((_, i) => !reviewResults[i]).map((d) => d.name)
const allIssues = reviewResults.filter(Boolean).flatMap((r) => r.issues || [])
let lastBuildTest = toBuildTest(probeResults[0], '构建/测试探测 agent 调用失败，没拿到结果')

const toFix = allIssues.filter((it) => it.severity === 'blocker' || it.severity === 'major')
const minors = allIssues.filter((it) => it.severity === 'minor')
if (lastBuildTest.passed !== true) {
  // isBuild 标记这条是注入的构建/测试项（不靠 location 文本识别，避免和评审写的 location 撞上）；它的最终状态单独看 lastBuildTest。
  toFix.push({ severity: 'blocker', description: `项目构建/测试当前未通过或结果未知（既有失败除外）：\n${lastBuildTest.output}`, isBuild: true })
}
log(`[${CHANGE}] review 发现 blocker/major ${toFix.length} 个（含构建/测试失败项），minor ${minors.length} 个（只记录不修）` +
  (missingDimensions.length ? `；${missingDimensions.join('、')} 角度没拿到结果` : ''))

// ---- Fix：一个修复 agent 修一次；修完由独立 agent 跑构建/测试（不信修复 agent 自己的说法），修坏了给一次针对性修复。不再做第二轮 review。 ----
let fixResult = null
if (toFix.length > 0) {
  phase('Fix')
  fixResult = await agent(
    `openspec change "${CHANGE}" 的代码 review 发现以下 blocker/major 级问题，请逐条处理（这是唯一的一次修复，之后不会再有 review；minor 不在范围内）：\n${issuesToText(toFix)}\n\n` +
    '对每一条先读代码核实问题是否真实存在，然后在 results 里给出它的处理结果（issueIndex 填上面列表里的编号，每一条都要有）：' +
    'fixed = 真实存在且已修（note 写修了什么、改在哪）；disputed = 核实后是误报（note 写具体理由，引用代码位置说明为什么不会发生，不能只写"不是问题"）；' +
    'not_fixed = 真实存在但这次没能修好（note 写卡在哪，比如需要产品决策、改动面超出本 change）。修不好就如实标 not_fixed，不要硬改。' +
    '只改本次 change 未提交的改动涉及的代码和测试；基准提交之前已经提交的内容（包括第二步单独提交的既有失败修复）不要动。' +
    `${FIX_GUARDRAILS}${baselineClause()}${skipClause()}` +
    `修改过程中可以自己${BUILD_RUN_NOTE}来确认，但最终结果以之后独立跑的构建+测试为准。`,
    { label: 'fix', phase: 'Fix', schema: FIX_SCHEMA }
  )
  // 不管修复 agent 成功与否（失败时它也可能已经改了一部分文件），都由独立 agent 重新跑一次拿真实状态。
  lastBuildTest = toBuildTest(await runBuild('build-after-fix', 'Fix'), '修复后的构建/测试 agent 调用失败，没拿到结果')
  if (lastBuildTest.passed === false) {
    log(`[${CHANGE}] 修复后构建/测试未通过，给一次针对性修复`)
    await agent(
      `openspec change "${CHANGE}" 的代码 review 修复之后，项目标准的构建+测试命令出现了本次改动引入的失败：\n${lastBuildTest.output}\n\n` +
      `请只针对这些失败修复（可以改代码和测试）。${FIX_GUARDRAILS}${baselineClause()}`,
      { label: 'build-repair', phase: 'Fix' }
    )
    lastBuildTest = toBuildTest(await runBuild('build-recheck', 'Fix'), '构建/测试复检 agent 调用失败，没拿到结果')
  }
}

// ---- 留痕：由脚本确定性生成，调用方原样写进 commit message / ROADMAP.md ----
const statusByIndex = new Map()
for (const r of (fixResult && fixResult.results) || []) {
  if (!statusByIndex.has(r.issueIndex)) statusByIndex.set(r.issueIndex, r)
}
const fixed = []
const disputed = []
const unresolved = []
toFix.forEach((it, i) => {
  if (it.isBuild) return // 构建/测试的最终状态单独看 lastBuildTest
  const r = statusByIndex.get(i + 1)
  if (r && r.status === 'fixed') fixed.push({ ...it, note: r.note })
  else if (r && r.status === 'disputed') disputed.push({ ...it, note: r.note })
  else unresolved.push({ ...it, note: r ? r.note : fixResult ? '修复 agent 没有报告这一条的处理结果' : '修复 agent 调用失败，未处理' })
})
const buildTestFailing = lastBuildTest.passed !== true

const knownGaps = [
  ...unresolved.map((it) => `[${CHANGE}] 代码 review 遗留 ${it.severity}：${issueRecordText(it)} —— ${oneLine(it.note)}`),
  ...(buildTestFailing ? [`[${CHANGE}] 代码 review 后构建/测试仍未通过或结果未知：${oneLine(lastBuildTest.output)}`] : []),
  ...missingDimensions.map((name) => `[${CHANGE}] 代码 review 的「${name}」角度 agent 调用失败，该角度未审查`),
]

const records = {
  // 非空 → commit 标题行末尾加 ` [known gaps]`，原样写进 commit message 和 ROADMAP.md「无法自主解决的问题」。
  knownGaps,
  // 原样写进 commit message 和 ROADMAP.md「已解决的问题」。只修了一次、没有再 review 确认，所以标明"未经复核"。
  fixed: fixed.map((it) => `[${CHANGE}] 代码 review 已修（未经复核）${it.severity}：${issueRecordText(it)} —— ${oneLine(it.note)}`),
  // 原样写进 commit message，留给人复查驳回是否站得住。
  disputed: disputed.map((it) => `[${CHANGE}] 代码 review 驳回 ${it.severity}：${issueRecordText(it)} —— 理由：${oneLine(it.note)}`),
  // 只写进 commit message，不修也不进 ROADMAP.md。
  minors: minors.map((it) => `[${CHANGE}] 代码 review minor（未修）：${issueRecordText(it)}`),
}

return {
  change: CHANGE,
  reviewBase: REVIEW_BASE,
  issueCount: allIssues.length,
  missingDimensions,
  fixResult,
  lastBuildTest,
  buildTestFailing,
  hasKnownGaps: knownGaps.length > 0,
  records,
}
