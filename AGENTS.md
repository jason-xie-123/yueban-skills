# AGENTS.md

> This file is the **single authoritative instruction source** for every AI agent in this repo (Claude Code / Codex / Gemini CLI, etc.).

## What this repo is

- An Agent Skills repo: it accumulates skills the owner has written that are reused across projects, distributed via `npx skills`. It is not product code.
- This repo is public. If a skill's content touches a specific project's internal conventions (env var names, directory layout, etc.), confirm whether it's appropriate to include here before doing so — don't decide what goes into a public repo on the user's behalf.

## Collaboration language

- Conversational replies default to Chinese.
- Skill bodies (`skills/<name>/SKILL.md`, etc.) and git commit messages default to English (see each skill's own convention, e.g. [[yueban-git-commit]]).
- Code identifiers, commands, paths, and proper nouns are kept as-is.

## Skill layering (this repo's core structure)

| Layer | Location | Distribution | Current members |
|---|---|---|---|
| Externally distributed skills | `skills/<name>/` | `npx skills add https://github.com/jason-xie-123/yueban-skills.git` | `yueban-doc-authority-audit`, `yueban-doc-md-title-export`, `yueban-docs-format-conversion`, `yueban-docs-freshness-audit`, `yueban-docs-prune-historical-comments`, `yueban-english-speaking-practice`, `yueban-git-commit`, `yueban-loop-openspec`, `yueban-spec-roadmap-flow`, `yueban-spec-single-change-flow` |

- `.agents/skills/` is this repo's own symlink directory (symlinked to `skills/<name>`, not checked in), letting maintainers edit `skills/` source files in this repo and have them take effect immediately for Claude Code / Codex / Gemini CLI.
- `.claude/skills`, `.codex/skills`, `.gemini/skills` are all symlinks pointing to `.agents/skills/`.
- **New skills** always go under `skills/<name>/` (this repo currently has no second "repo-internal only, not distributed" layer — everything here exists to be installed by other projects).

## Skill invocation discipline

- Each skill declares its own trigger conditions in frontmatter — **respect each skill's own `description`**: for skills marked "only on explicit user invocation" (e.g. `yueban-doc-authority-audit`), don't auto-enable it just because a task looks like a match; use `yueban-git-commit` when the user asks to commit code, create a commit, or mentions `/commit`.

## Supported AI agent clients

| Client | Entry command | Config/extension location |
|---|---|---|
| Claude Code | `claude` | `AGENTS.md`, `.claude/skills → ../.agents/skills` |
| OpenAI Codex CLI | `codex` | `AGENTS.md`, `.codex/skills → ../.agents/skills` |
| Gemini CLI | `gemini` | `AGENTS.md`, `.gemini/skills → ../.agents/skills` |

## Index of other capabilities

- External skill install/update/uninstall commands, local dev workflow: `README.md`

## Things not to do

- Don't write plaintext credentials (API tokens, secrets, passwords) into any file in this repo.
- Don't reserve abstractions for "might need it someday" scenarios.
- Don't cram multiple unrelated changes into a single commit.
- Don't run destructive git operations (`reset --hard`, `push --force`, `filter-repo`, etc.) without user confirmation.
