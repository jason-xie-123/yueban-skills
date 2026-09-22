---
name: yueban-doc-md-title-export
description: 仅当用户明确指名此技能时使用（例如"用 yueban-doc-md-title-export 处理一下"/ "/yueban-doc-md-title-export" / "跑一下标题清理+PDF导出流程"）。不要根据任务内容自动选用——即使任务高度匹配 markdown 标题清理/文件名校验/md 转 PDF 场景，也需要用户明确调用。
---

# yueban-doc-md-title-export · Markdown 标题清理 + 文件名检查 + PDF 导出

## 概述

对**单个 Markdown 文件**做三件事：

1. **确保文档有且仅有一个合理的顶层标题**（H1）
2. **检查文件名是否遵循 kebab-case、多段式命名**（`aaa-bbb-ccc-xxxx.md`）
3. **导出为同名 PDF**，文件名取自最终的 H1 标题

**核心约束 · 最小改动原则**：

- **没必要改的不要改** —— 如果标题"已经足够好"，保留原文措辞；如果文件名"合法"，不要重命名
- 只有偏差**严重**时才动手（判断标准见下方"何时改动"）
- 任何改动之前，先向用户以"现状 / 判定 / 拟议改动"三段式呈现——**不要静默改写任何内容**

## 何时使用

仅当**用户明确指名此技能**时触发（例如 `/yueban-doc-md-title-export` / "用 yueban-doc-md-title-export 处理一下" / "跑一下标题清理+PDF导出流程"）。

**不应自动触发的反例**：

- 用户只说"把这个 md 转成 PDF" → 直接用 pandoc / chrome headless，跳过本技能的三步流程
- 用户只说"看看这份文档的标题对不对" → 正常对话即可，不必强行套用本技能的输出格式
- 用户说"帮我整理一下这个文件名" → 给出通用的重命名建议即可

**不适用于**：批量目录处理（本技能只针对单个文件）/ 文档内容审计（用 [[yueban-doc-authority-audit]]）/ 文档语言润色（如果环境里装了专门的语言润色技能，先用那个；本仓库目前没有内置这类技能）。

## 工作流程（顺序执行，各步骤相互独立）

### 步骤 1 · 读取 + 提取现状

读取完整的 md 文件，提取三个事实：

| 字段 | 提取方法 |
|---|---|
| `current_title` | 第一个 `# xxx` 行的 H1 文本；若无 H1，记为 `null` |
| `current_filename` | 不含扩展名的基础文件名，例如 `My_Doc-v2.md` → `My_Doc-v2` |
| `inferred_topic` | 读取正文前 30%，用一句话总结主题（后续用于判断标题是否"严重偏离"） |

> 注意：如果文档以 YAML frontmatter（用 `---` 包裹）开头，H1 应在 frontmatter **之后**提取。frontmatter 内的 `title:` 字段**不算** H1。

### 步骤 2 · 标题判定 + 最小改动

判定流程：

```
当前是否存在 H1？
├─ 否 → 添加一个 H1（根据 inferred_topic 或文件名生成，交给用户确认）
└─ 是 → H1 是否与正文主题"严重偏离"？
        ├─ 否 → 不改动（即使措辞可以更好也保留）
        └─ 是 → 提出改写建议，并说明理由
```

**"严重偏离"的判定标准**（**满足任意一条**即视为严重）：

- H1 与正文主题完全无关（例如正文讲 Stripe 集成，但 H1 是"TODO" / "Untitled" / "test"）
- H1 不携带任何信息（"文档" / "笔记" / "草稿"）
- H1 有明显拼写错误 / 被截断（"System Integration Guide v"、"# # Title"）

**不算严重**（**保持原样**）：

- 措辞可以略作改进，但含义清晰
- 大小写/标点风格与项目惯例不完全一致
- 不够"漂亮"，但准确传达了含义

### 步骤 3 · 文件名判定 + 最小改动

有效 kebab-case 多段式命名 `aaa-bbb-ccc-xxxx.md` 的标准（**必须全部满足**）：

- 全部小写
- 只包含 `[a-z0-9-]` —— 不含空格、下划线、大写字母、中文字符或特殊字符
- 用 `-` 分段，**至少 2 段**（`note.md` 属于"分段不足"，但除非同时满足下面"严重"的标准，否则**不强制修改**）
- 不以 `-` 开头/结尾，没有连续的 `--`

**"严重偏离"的判定标准**（**满足任意一条**即视为严重）：

- 包含空格（`my doc.md`）
- 包含大写字母（`MyDoc.md`）
- 以下划线作为主要分隔符（`my_doc_v2.md`）
- 包含中文或其他非 ASCII 字符（例如文件名全是中日韩字符）
- 包含特殊字符（`doc@v2.md`、`doc(final).md`）

**不算严重**（**保持原样**）：

- 单段但已经合法（`readme.md`、`changelog.md`）
- 段数较少但合法（`stripe-integration.md`，2 段）
- 包含数字/版本号（`api-v2.md`、`spec-2024.md`）

> 重命名时，**不要直接执行** `mv` —— 先呈现一个"现状 → 拟议"对照表，等用户确认后再执行。

### 步骤 4 · 三段式输出 + 等待确认

在做任何改动之前，输出：

```
## 现状

- 当前标题：{current_title 或 "（无 H1）"}
- 当前文件名：{current_filename}.md
- 正文主题：{inferred_topic}

## 判定

- 标题：{保留 / 需要改写}，理由：{...}
- 文件名：{保留 / 需要重命名}，理由：{...}

## 拟议改动

- 标题：{不改动 / 改为 "{new_title}"}
- 文件名：{不改动 / 重命名为 "{new_filename}.md"}
- PDF 输出：{final_title}.pdf
```

**只有**在用户确认或明确表示"按你的判定来"之后，才进入步骤 5。

### 步骤 5 · 应用改动 + 导出 PDF

按已确认的方案：

1. **更新 H1**：使用 Edit 工具替换，或在文件顶部插入 H1
2. **重命名文件**：`mv old.md new.md`（如适用）
3. **导出为 PDF**：见下方"PDF 导出"部分

PDF 文件名取自**最终 H1 文本**，按以下规则做文件系统安全清洗：

- 移除/替换：`/` `\` `:` `*` `?` `"` `<` `>` `|` `\0`
- 保留中文字符、空格及其他符号
- 输出到与 md 文件**相同的目录**

示例：H1 为 `Stripe / Adyen Integration Guide` → PDF 为 `Stripe ／ Adyen Integration Guide.pdf`（`/` 转换为全角字符）

## PDF 导出工具链（按优先级排列）

> 在 macOS 上，**优先级 1**（pandoc + xelatex）的安装步骤记录在 [setup-pandoc-xelatex.md](./setup-pandoc-xelatex.md) 中。

运行前先探测环境，按以下顺序选取第一个可用选项：

| 优先级 | 工具 | 探测命令 | 调用方式 |
|---|---|---|---|
| 1 | `pandoc` + LaTeX | `which pandoc xelatex` —— 两者都存在 | 见下方"优先级 1 完整命令"（中文/ASCII 图表内容需要同时具备 mono + CJKmono 字体） |
| 2 | `pandoc` + `weasyprint` | `which pandoc weasyprint` | `pandoc input.md -o "TITLE.pdf" --pdf-engine=weasyprint` |
| 3 | `pandoc` + `wkhtmltopdf` | `which pandoc wkhtmltopdf` | `pandoc input.md -o "TITLE.pdf" --pdf-engine=wkhtmltopdf` |
| 4 | Chrome / Edge headless | macOS 通常预装 Chrome | 先 `pandoc input.md -s -o tmp.html`，再 `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu --print-to-pdf="TITLE.pdf" "file://$(pwd)/tmp.html"` |
| 5 | `npx md-to-pdf` | 需要 Node | `npx --yes md-to-pdf input.md && mv input.pdf "TITLE.pdf"` |

**优先级 1 完整命令**（针对中文文档 + ASCII 拓扑图，网络拓扑类文档的典型形态）：

```bash
pandoc input.md -o "TITLE.pdf" --pdf-engine=xelatex \
  -V CJKmainfont="PingFang SC" -V mainfont="PingFang SC" \
  -V monofont="Menlo" -V CJKmonofont="PingFang SC" \
  -V geometry:margin=1.5cm \
  -V monofontoptions="Scale=0.80" -V CJKmonofontoptions="Scale=0.80" \
  2>warnings.log; echo "exit=$?"; grep -c "Missing character" warnings.log
```

三套字体缺一不可：

- `CJKmainfont` / `mainfont`：**正文**中文（只设置这个 ≠ 完事，见"常见错误"）。
- `monofont="Menlo"`：**代码块中的制表/框线字符与符号**（`─ │ ├ └`、`≤` 等）。LaTeX 默认的等宽字体 `lmmono10` 没有这些字符——ASCII 图表会显示破损。Menlo / JetBrainsMono Nerd Font 都包含框线字符。
- `CJKmonofont="PingFang SC"`：**代码块内的中文标签**（例如架构图内的中文标注）。`CJKmainfont` 覆盖不到代码块。

`geometry:margin` + `Scale=0.80` 用于防止宽图表溢出——架构图通常宽达 70+ 列，在默认页宽下会被截断。

**当所有方案都失败时**：不要静默退出——把探测过的每条命令及其 stderr 都列给用户，由用户选择安装哪个后端。

**彩色 emoji（🔄🟢 等）xelatex 无法渲染**：会产生 `Missing character` 警告并在 PDF 中显示为空白。如果彩色 emoji 出现在关键内容中，切换到优先级 4（Chrome headless，通过浏览器可正确渲染 emoji）；如果 emoji 只出现在描述性文字中，可以接受丢失并告知用户。

## 常见错误

### 把"措辞可以更好"当成"严重偏离"

H1 是"Stripe Integration"，正文是一份完整的 Stripe 集成指南。**不要**擅自改成"Complete Stripe Integration Guide v1"。最小改动原则：含义正确就保留。

### 把 YAML frontmatter 的 title 当作 H1

frontmatter 中的 `title: xxx` 字段不属于文档正文——有些渲染器会把它当作显示用的 H1，但**它不是 markdown 的 H1**。本技能只把正文中以 `# xxx` 开头的行识别为 H1；frontmatter 的 title 是元数据。

### 静默重命名 / 静默改写

任何改动都必须**先经过步骤 4 的三段式呈现**并等待用户确认。绝不要说"我已经把文件重命名为 xxx 并导出了 PDF"——这违背了最小改动原则的初衷，即保留用户的否决权。

### 用了清洗后的 PDF 文件名，却忘了 H1 应保持不变

如果 H1 是 `Stripe / Adyen`，PDF 必须是 `Stripe ／ Adyen.pdf`（非法字符被替换），但**不要**因此反过来去改 H1。文件名清洗和 H1 是相互独立的。

### 以为传了 CJKmainfont 就够了（代码块内的中文/ASCII 图表仍会丢字符）

`-V CJKmainfont="PingFang SC"` 只覆盖**正文**中文。代码块（fenced code blocks）使用独立的等宽字体，`CJKmainfont` **覆盖不到**。所以带 ASCII 拓扑图 + 中文标注的文档（网络拓扑类文档的典型形态），即使设置了 CJKmainfont，代码块内仍会：缺失框线字符 `─│├└`（图表破损）、缺失中文标注。必须同时设置 `-V monofont="Menlo"`（框线/符号）+ `-V CJKmonofont="PingFang SC"`（代码块内中文）。见"优先级 1 完整命令"。

### 以为 exit=0 就代表渲染成功（缺字符会被静默丢弃，不报错）

pandoc+xelatex 遇到字体中缺失的字符时，**只会打印 `Missing character` 警告并丢弃该字符——退出码仍是 0**。只检查退出码会漏掉"图表完全破损"这类严重问题。导出后**必须**验证：重定向 `2>warnings.log`，再 `grep -c "Missing character" warnings.log`——非零计数表示有字符被丢弃；用 `grep -oE "U\+[0-9A-F]+"` 查看具体是哪些字符（框线/中文 → 补齐缺失字体后重新导出；只有彩色 emoji → 接受丢失或切换到 Chrome）。

### 任何探测失败就直接切换下一个引擎

某个 PDF 引擎报错时，**保留 stderr**——不要只看退出码就静默回退。如果多个引擎都失败，把累积的错误展示给用户（通常是同一个根因——缺字体、权限问题、临时 HTML 路径问题——换引擎也解决不了）。

## 速查表

| 阶段 | 动作 |
|---|---|
| 步骤 1 | 读取 md，提取 current_title / current_filename / inferred_topic |
| 步骤 2 | 判断 H1：只有缺失或严重偏离才改动 |
| 步骤 3 | 判断文件名：只有含空格/大写/下划线/中文/特殊字符才改动 |
| 步骤 4 | 以三段式输出现状 + 判定 + 拟议改动，等待确认 |
| 步骤 5 | 编辑 H1 → mv 重命名 → 探测 PDF 引擎 → 导出 `{title}.pdf` |

## 集成

- **同场景的搭档**：如果环境里装了专门的语言润色技能，应在本技能**之前**运行——本技能不涉及正文措辞，只处理 H1 和文件名（本仓库目前没有内置这类技能）
- **不要与之组合**：[[yueban-doc-authority-audit]] 是事实审计；本技能是表层清理——两者目标不同
