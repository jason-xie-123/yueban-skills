# pandoc + xelatex PDF 导出环境搭建

记录 [SKILL.md](./SKILL.md) 中引用的**优先级 1**（pandoc + xelatex）PDF 导出选项的安装步骤和背景，以便在新机器上一次性搭好环境。

## 为什么选这条链路

相比 weasyprint / wkhtmltopdf / Chrome headless / md-to-pdf：

- **排版效果最好** —— LaTeX 是出版级排版引擎，分页、孤行/寡行控制、字间距、目录、脚注、交叉引用都比 HTML→PDF 路线更精细一个档次
- **中文最可靠** —— 通过 xelatex + `CJKmainfont="PingFang SC"` 直接驱动系统真实字体，避免豆腐块、丢字、标点压缩错误
- **代码块 / 表格 / 公式** —— 语法高亮、对齐、数学公式都是原生 LaTeX 质量
- **跨机器一致** —— LaTeX 产出的 PDF 不受浏览器版本 / DPI / 字体回退影响
- **适合长文档** —— 自动目录、章节编号、页眉页脚都是原生支持

代价：体积较大（BasicTeX 约 100MB / MacTeX 约 5GB），首次安装较慢。

## macOS 安装（推荐 BasicTeX 路线）

```bash
# 1. pandoc（已安装则跳过）
brew install pandoc

# 2. BasicTeX（精简版 TeX Live，约 100MB）
brew install --cask basictex

# 3. 刷新 PATH（BasicTeX 安装到 /Library/TeX/texbin）
eval "$(/usr/libexec/path_helper)"
# 若要永久生效：把下面这行追加到 ~/.zshrc
#   export PATH="/Library/TeX/texbin:$PATH"

# 4. 升级 tlmgr 并安装中文 PDF 所需的包
sudo tlmgr update --self
sudo tlmgr install xecjk ctex fandol collection-fontsrecommended
```

如果磁盘空间充足、想一次装齐（完整字体集，之后无需再装 tlmgr 包），改为安装：

```bash
brew install --cask mactex-no-gui   # 约 4GB，不含 GUI 工具，但命令行工具链完整
```

## 验证

```bash
which pandoc xelatex
pandoc --version | head -1
xelatex --version | head -1
```

两条命令都打印出路径和版本号，说明环境已就绪。

## 生成 PDF

针对中文文本 + ASCII 拓扑图（网络拓扑类文档的典型形态）的完整命令：

```bash
pandoc input.md -o "TITLE.pdf" --pdf-engine=xelatex \
  -V CJKmainfont="PingFang SC" -V mainfont="PingFang SC" \
  -V monofont="Menlo" -V CJKmonofont="PingFang SC" \
  -V geometry:margin=1.5cm \
  -V monofontoptions="Scale=0.80" -V CJKmonofontoptions="Scale=0.80" \
  2>warnings.log; echo "exit=$?"; grep -c "Missing character" warnings.log
```

> 三项字体设置缺一不可：`CJKmainfont` 覆盖正文中文；`monofont`（Menlo）覆盖代码块内的框线字符
> `─│├└`；`CJKmonofont` 覆盖代码块内的中文标签。只设置 `CJKmainfont` 会导致 ASCII 图表破损、
> 代码块内中文丢失——因为代码块使用独立的等宽字体，`CJKmainfont` 覆盖不到。
>
> 导出后 `grep -c "Missing character"` 的结果必须为 0：xelatex 会静默丢弃缺失的字符，退出码
> 仍是 0——只检查退出码会漏掉图表破损这类问题。

所用字体 `PingFang SC` / `Menlo` 都是 **macOS 内置**的——无需额外安装。

## 常见坑

### `xelatex: command not found`（安装后仍找不到）

`/Library/TeX/texbin` 不在 PATH 中。临时修复当前 shell：

```bash
eval "$(/usr/libexec/path_helper)"
```

永久生效：把下面这行追加到 `~/.zshrc`（或 `~/.bashrc`）：

```bash
export PATH="/Library/TeX/texbin:$PATH"
```

### `! LaTeX Error: File 'xeCJK.sty' not found.`

BasicTeX 默认不带 xeCJK；运行一次：

```bash
sudo tlmgr install xecjk ctex
```

### 中文显示为方块 / 丢字

没有传 `-V CJKmainfont=...`，或者传入的字体名在系统上未安装。macOS 内置可选：

- `PingFang SC`（推荐默认）
- `Heiti SC`
- `Songti SC`

非 macOS 系统上改用 `Noto Sans CJK SC`（需要单独安装）。

### 代码块内 ASCII 图表破损 / 中文丢失

会产生大量 `Missing character: There is no ─ (U+2500) ... in font [lmmono10-regular]`（或中文
字符的同类警告）。根本原因：代码块使用**独立的等宽字体**，默认的 `lmmono10` 既没有框线字符
也没有中文字形——`-V CJKmainfont` 覆盖不到它，因为它只作用于正文文本。需要同时加上两项字体
设置：

```bash
-V monofont="Menlo" -V CJKmonofont="PingFang SC"
```

宽图表（70+ 列的拓扑图）还会超出页宽被截断；再加上
`-V geometry:margin=1.5cm` + `-V monofontoptions="Scale=0.80" -V CJKmonofontoptions="Scale=0.80"`。

### 彩色 emoji（🔄🟢 等）在 PDF 中显示为空白

xelatex 不支持彩色 emoji 字体（Apple Color Emoji 是位图字体，强制使用通常会报错或仍然渲染
为空白）。如果 emoji 出现在关键内容中，切换到 SKILL.md 的优先级 4（Chrome headless）；如果
emoji 只出现在描述性文字中，可以接受丢失。

### 运行 pandoc 时打印一堆 `command not found: _encode / _decode`

类似下面的错误：

```
setValueForKeyFakeAssocArray:27: command not found: _encode
valueForKeyFakeAssocArray:28: command not found: _decode
```

来自 zsh 与 `eval "$(/usr/libexec/path_helper)"` 的组合，触发原因是某些关联数组辅助函数在
非交互式 shell 中没有被自动加载。**不影响 pandoc**——退出码仍是 0，PDF 仍会正常生成。

要消除它，跳过 `path_helper`，改用显式 export：

```bash
export PATH="/Library/TeX/texbin:$PATH"
```

这行写进 `~/.zshrc` 后，新开的 shell 中运行 pandoc 就不会再有这个问题。

### `tlmgr: Local TeX Live ... is older than remote repository`

```bash
sudo tlmgr update --self --all
```

如果仍然报错（通常发生在跨主版本年份边界时），查阅官方 TeX Live 升级指南手动升级发行版版本。

## 相关文档

- [SKILL.md](./SKILL.md) —— 本技能的主文档；PDF 导出工具链的 5 级优先级列表在其"PDF 导出工具链"部分
