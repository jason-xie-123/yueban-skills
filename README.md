# yueban-skills

A collection of Agent Skills, installable into any project via [`npx skills`](https://github.com/vercel-labs/skills). Skills all live under `skills/<name>/`.

## Installation

Requires Node.js (which bundles `npx`).

```bash
# Install every skill in this repo (interactively pick target agents: Codex / Claude Code / Gemini CLI, etc.)
npx skills add https://github.com/jason-xie-123/yueban-skills.git

# Install only a specific skill
npx skills add https://github.com/jason-xie-123/yueban-skills.git --skill <skill-name>

# Non-interactive: install into Claude Code + Codex + Gemini CLI, project scope, skip confirmation
npx skills add https://github.com/jason-xie-123/yueban-skills.git --skill <skill-name> -a claude-code -a codex -a gemini-cli -y
```

Common maintenance commands:

```bash
npx skills list                      # List skills installed on this machine (including install scope)
npx skills update                    # Update to the repo's latest version (interactively pick scope; updates everything if no args given)
npx skills update <skill-name> -g    # Update only the given skill; -g = global scope
npx skills remove <skill-name>       # Uninstall
```

Notes:

- Without `-g`, skills install into the **current project** (e.g. `.agents/skills/`, checked in with the project); with `-g` they install into the **user's home directory** (available to all projects).
- `npx skills` is **copy-based distribution**: the local copy is decoupled from this repo — after a skill is updated here, each consumer needs to run `npx skills update` on their end.

## Skill list

| Skill | Purpose | Trigger |
|---|---|---|
| [yueban-doc-authority-audit](skills/yueban-doc-authority-audit/SKILL.md) | Four-dimension documentation audit against official authoritative sources | Only on explicit invocation (`/yueban-doc-authority-audit` or "use yueban-doc-authority-audit on this...") |
| [yueban-doc-md-title-export](skills/yueban-doc-md-title-export/SKILL.md) | Markdown title cleanup + filename check + PDF export | Only on explicit invocation (`/yueban-doc-md-title-export` or "use yueban-doc-md-title-export on this...") |
| [yueban-docs-format-conversion](skills/yueban-docs-format-conversion/SKILL.md) | Inventory a docs directory's mixed html/docx/xlsx/pdf files and convert to AI-friendly formats | Only on explicit invocation (`/yueban-docs-format-conversion` or "use yueban-docs-format-conversion on this...") |
| [yueban-docs-freshness-audit](skills/yueban-docs-freshness-audit/SKILL.md) | Audit AGENTS.md/README.md/spec.md/business docs for staleness (dangling references, contradictions, broken links, cross-doc inconsistency, stale command/paths, etc.) and fix issues directly | Only on explicit invocation (`/yueban-docs-freshness-audit`) |
| [yueban-proj-prune-historical](skills/yueban-proj-prune-historical/SKILL.md) | Scan and remove "how this used to be, then changed to" historical-narrative source comments and doc passages across the whole project (root repo and every active submodule, treated the same way) that no longer guide current behavior | Only on explicit invocation, or when the user says this kind of historical-narrative comment is unnecessary |
| [yueban-english-speaking-practice](skills/yueban-english-speaking-practice/SKILL.md) | English speaking practice (scenario simulation / role-play) | When the user wants to practice speaking |
| [yueban-git-commit](skills/yueban-git-commit/SKILL.md) | Git commit workflow following Conventional Commits | When the user asks to commit code, create a commit, or mentions `/commit` |
| [yueban-git-feature-branch-flow](skills/yueban-git-feature-branch-flow/SKILL.md) | Cut a same-named feature branch across a superproject and its active submodules, keep it in sync across machines, and report merge readiness | Only on explicit invocation (`/yueban-git-feature-branch-flow`) |
| [yueban-git-safe-sync](skills/yueban-git-safe-sync/SKILL.md) | Pull/push in a submodule-based repo without ever detaching submodule HEADs or checking them out by recorded SHA | Only on explicit invocation (`/yueban-git-safe-sync`) |
| [yueban-spec-loop](skills/yueban-spec-loop/SKILL.md) | Turn a Goal into an unattended OpenSpec loop (explore → propose → apply → verify → archive) | Claude Code only; explicit invocation only (`/yueban-spec-loop <goal>`, or `/loop /yueban-spec-loop <goal>` for unattended runs) |
| [yueban-spec-roadmap-flow](skills/yueban-spec-roadmap-flow/SKILL.md) | Drive an entire OpenSpec ROADMAP.md to completion, change by change | Only when the user explicitly asks to run through the whole roadmap |
| [yueban-spec-single-change-flow](skills/yueban-spec-single-change-flow/SKILL.md) | Review/implement/verify a single OpenSpec change through its full cycle | Only on explicit invocation |

## Repo layout

```
skills/                  # Externally distributed skills (npx skills' discovery directory)
  <name>/
    SKILL.md             # Skill definition (trigger conditions / workflow / hard limits)
    ...                  # Any other subdirectories/files (references/scripts/templates, etc.) are up to each skill
.agents/skills/          # This repo's own symlinks (symlinked to skills/<name>, not checked in)
.claude/skills           # Symlink → ../.agents/skills, makes skills visible to Claude Code
.codex/skills            # Symlink → ../.agents/skills, makes skills visible to Codex
.gemini/skills           # Symlink → ../.agents/skills, makes skills visible to Gemini CLI
scripts/
  link-skills.sh         # Symlinks each skill under skills/ into .agents/skills/ (for local development)
```

## Adding a new skill

```bash
npx skills init <skill-name>   # Generate a SKILL.md template under skills/<skill-name>/
scripts/link-skills.sh         # Create symlinks + sync .gitignore, so the new skill is visible to agents in this repo
```

SKILL.md must include YAML frontmatter (`name`, `description`); see [agentskills.io](https://agentskills.io) for the spec. Restart the agent session after linking for it to discover the new skill.

## Local development and testing

Don't install your own skill in this repo with `npx skills add` (it's copy-based — editing the source won't take effect). Instead, create a symlink under `.agents/skills/` so it's visible to every agent client in this repo, with edits to the `skills/` source taking effect immediately:

```bash
scripts/link-skills.sh            # Create/fix symlinks for every skill under skills/, and sync .gitignore
scripts/link-skills.sh --dry-run  # Show what would be done, without changing anything
scripts/link-skills.sh --help     # All options (--force / --prune / --no-gitignore)
```

- Symlinks are **not checked in** (the `skills/` source is authoritative; each machine creates its own locally); the script automatically fills in the matching `.gitignore` lines.
- Restart the agent session after linking for it to discover the new skill.
