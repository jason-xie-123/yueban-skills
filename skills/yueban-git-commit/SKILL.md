---
name: yueban-git-commit
description: 'Commit with a Conventional Commits message generated from the diff, with smart staging and an optional push once confirmed. Use when asked to commit code or on /commit.'
allowed-tools: Bash
---

# Git Commit with Conventional Commits

## When to use

Perform a git commit following Conventional Commits, with commit message analysis, smart staging, and message generation. Use when the user asks to commit code, create a commit, or mentions "/commit". Supports: (1) auto-detecting type and scope from the diff, (2) generating a conventional commit message from the diff, (3) interactive commits (overriding type/scope/description), (4) smart staging by logical grouping, (5) pushing to the remote after commit, once confirmed (skip asking only if the user's request already implied pushing).

## Overview

Create standardized, semantic git commits based on Conventional Commits. Determine the appropriate type, scope, and message by analyzing the actual diff.

## Commit format

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

## Commit language convention

1. Write `description` and `body` in English by default, unless the user explicitly asks for Chinese.
2. Keep `type`, `scope`, and convention keywords (e.g. `BREAKING CHANGE`, `Refs`, `Closes`) in their standard English form.
3. Leave proper nouns, code identifiers, paths, and commands as-is — do not force-translate them.

## Commit types

| Type       | Purpose                          |
| ---------- | --------------------------------- |
| `feat`     | New feature                       |
| `fix`      | Bug fix                           |
| `docs`     | Documentation only                |
| `style`    | Formatting/style change (no logic change) |
| `refactor` | Refactor (not a new feature, not a fix) |
| `perf`     | Performance improvement           |
| `test`     | Add/update tests                  |
| `build`    | Build system/dependency changes   |
| `ci`       | CI/config changes                 |
| `chore`    | Maintenance/misc changes          |
| `revert`   | Revert a commit                   |

## Breaking changes

```
# Add an exclamation mark after type/scope
feat!: remove deprecated endpoint

# Use a BREAKING CHANGE footer
feat: support config inheritance from other configs

BREAKING CHANGE: `extends` field behavior has changed
```

## Workflow

### 1. Analyze the diff

First make sure HEAD is on a branch. A commit on a detached HEAD (common in a fresh git worktree or a submodule after `git submodule update`) belongs to no branch and is easy to lose, so stop and ask the user which branch to switch to or create instead of committing:

```bash
git symbolic-ref -q --short HEAD || echo "Detached HEAD — switch to or create a branch first"
```

Then look at the changes:

```bash
# If files are already staged, check the staged diff
git diff --staged

# If nothing is staged, check the working tree diff
git diff

# Also check status — a submodule with ANY changes (committed-but-unpushed
# inside it, or still-uncommitted working tree changes) shows up here as
# e.g. " M <submodule-path>", regardless of which case it is
git status --porcelain

# If this repo tracks submodules (.gitmodules exists) and status shows one as
# modified, check further — `+` here only means the submodule's checked-out
# commit differs from the parent's recorded pointer: it may be ahead, behind,
# or diverged, the prefix does not say which. A submodule can also have
# uncommitted working-tree changes with NO `+` shown (git submodule status
# only compares HEAD to the recorded SHA, it does not report dirty working trees)
if [ -f .gitmodules ]; then
  git submodule status
fi
```

If `git status --porcelain` lists a submodule path at all (` M`, or `A ` for a newly added one), **stop here and resolve it via the "Handling submodules" section below before continuing to step 2** — don't rely on the `+` prefix alone to decide whether it's safe to proceed, since a submodule with uncommitted (not yet committed inside it) changes shows no `+` at all. Run `git -C <submodule-path> status --porcelain` to see whether the submodule's own working tree is dirty (case 1: needs a commit + push inside the submodule first) or clean (case 2: the pointer moved — confirm it moved forward and is pushed before recording it). A newly added submodule is case 3. An untracked directory that contains its own `.git` (`?? <dir>/` in status) is a nested repository that was never added as a submodule — stop and ask the user; `git add` would record it as a pointer with no `.gitmodules` entry, which breaks every clone.

### 2. Stage files (if needed)

When nothing is staged yet, or you want to reorganize the change groupings, first decide how many commits this should be — don't jump straight to staging everything as one group:

- Read the full unstaged diff (`git diff`) and list every changed file with a one-line summary of what changed in it.
- Group files by *why* they changed, not by directory or file type: two files touched for the same reason (implementing one feature, fixing one bug, one refactor) are one group, even if they live in unrelated directories. Two files that happen to sit next to each other but serve unrelated changes (e.g. an unrelated typo fix picked up along the way) are separate groups.
- A file that mixes multiple unrelated hunks needs a **partial stage** — don't force a mixed file into a single group just because splitting it is more work. Don't use `git add -p`: without a terminal it stages nothing and still exits 0. Write the file's diff to a patch, delete the hunks that belong to other groups, and apply the rest to the index (see below).
- If every changed file genuinely serves one purpose, one group (and one commit) is correct — don't manufacture multiple commits from a single logical change just to seem thorough.
- When the grouping is ambiguous (e.g. it's unclear whether two changes are "the same reason" or coincidentally adjacent), ask the user rather than guessing — a wrong split/merge is harder to undo than a short question.

```bash
# Stage specific files
git add path/to/file1 path/to/file2

# Stage by pattern — quote it so git matches the pathspec recursively;
# unquoted, zsh fails with "no matches found" and bash expands top-level files only
git add '*.test.*'
git add 'src/components/*'

# Stage part of a file — for files that mix multiple logical groups.
# Edit /tmp/part.patch to drop the hunks that belong to other groups first.
git diff -U0 -- path/to/mixed-file > /tmp/part.patch
git apply --cached --unidiff-zero /tmp/part.patch
# (add --recount if you edited lines inside a kept hunk)

# Stage all tracked/untracked changes at once — only once you've confirmed
# every changed file genuinely belongs to the same logical group, and no
# submodule shows up in `git status` (see "Handling submodules")
git add -A

# Same, but never staging submodule pointers — use this whenever a submodule
# path shows up in `git status`
git add -A -- . $(git config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print ":(exclude)" $2}')
```

For a multi-group diff, repeat step 2 → step 3 → step 4 once per group (stage that group only, commit it, then move to the next group) rather than staging everything up front.

**Never commit sensitive information** (e.g. `.env`, `credentials.json`, private keys).

### 3. Generate the commit message

Analyze the diff and determine:

- **Type**: What category of change is this?
- **Scope**: Which module/area is affected?
- **Description**: A one-line description of the change (present tense, imperative mood, < 72 chars)

### 4. Perform the commit

```bash
# Confirm the staging area isn't empty before committing
if git diff --cached --quiet; then
  echo "Nothing staged — run git add first"
  exit 1
fi

# Single-line commit message
git commit -m "<type>[scope]: <description>"

# Multi-line commit message (with body/footer)
git commit -m "$(cat <<'EOF'
<type>[scope]: <description>

<optional body>

<optional footer>
EOF
)"
```

### 5. Push to the remote

Pushing is a side-effecting action visible to others — confirm with the user before doing it, the same way `yueban-git-safe-sync`/`yueban-git-feature-branch-flow` require confirmation before their own push steps. Skip asking only when the user's own request already implied it (e.g. "commit and push this", "commit, then push to origin"). After the commit succeeds (and, unless already implied, after the user confirms), push:

```bash
git push
# If there's no upstream, use: git push -u origin HEAD
```

If `git push` refuses because the upstream has a different name (a branch created from `origin/develop` tracks `develop`), push with `git push -u origin HEAD` — don't follow git's hint to push to the other branch name, which publishes the work straight onto that branch.

## Handling submodules

If the repository tracks git submodules (see `.gitmodules`), they can show up in the parent repo's `git status`/`git diff` in two different ways — always tell them apart before staging:

1. **The submodule itself has uncommitted changes (dirty submodule)** — `git status` in the parent reports it as "modified content" or "untracked content" (or just `M <path>` in `--porcelain` output). Check with `git -C <submodule-path> status --porcelain`: any output means the submodule's own working tree has changes that were never committed inside the submodule. Note that `git submodule status` will **not** show a `+` prefix for this case — `+` only appears once the submodule's HEAD differs from the parent's recorded pointer, not while it's merely dirty.
   - Do not `git add <submodule-path>` directly in the parent repo — it records the submodule's current HEAD commit and silently leaves the uncommitted changes out, so the parent's commit looks complete while the work still sits, uncommitted, only inside the submodule.
   - `cd` into the submodule first and commit (and push) there, following the same Conventional Commits workflow, within the submodule's own history/conventions.
   - Pushing the submodule is what makes the parent's pointer valid, so ask the user to confirm that push (step 5) before committing in the parent; if they decline, don't stage the pointer in the parent.
   - Once the submodule's commit is pushed, the submodule is in case 2: run both case 2 checks before staging the pointer — committing inside the submodule doesn't guarantee its HEAD contains the commit the parent already records (for example, the parent records a colleague's commit from another branch).

2. **Only the pointer moved (submodule HEAD changed, working tree clean)** — `git -C <submodule-path> status --porcelain` is empty, but `git submodule status` shows a `+` prefix. Usually someone committed inside the submodule and the parent repo just needs to record the new commit SHA — but the same `+` also shows when the submodule is *behind* the recorded pointer (e.g. the parent was pulled and now records a newer submodule commit that the submodule's branch hasn't caught up to). Recording the pointer then rewinds it and drops someone else's submodule commits. Before staging, run both checks:

   ```bash
   # Fetch first: the recorded commit may not be in the submodule yet, and the
   # published check needs fresh, pruned remote branches
   git -C <submodule-path> fetch --quiet --prune origin || echo "fetch failed — cannot confirm anything is published"
   rec="$(git rev-parse HEAD:<submodule-path>)"
   cur="$(git -C <submodule-path> rev-parse HEAD)"
   # 1. Forward only: the recorded commit must be contained in the submodule's HEAD
   git -C <submodule-path> merge-base --is-ancestor "${rec}" "${cur}" && echo forward || echo "NOT forward"
   # 2. Published: some branch on the submodule's origin must contain HEAD
   git -C <submodule-path> branch -r --contains "${cur}" --list 'origin/*'
   ```

   `origin` here is the remote whose URL matches the submodule's `url` in `.gitmodules` (`git -C <submodule-path> remote -v`); if it has another name, use that name in both commands. A commit that is only on another remote, such as a personal fork, is not published for anyone cloning the project.
   - **Fetch failed**: stop — the published check would be answered from stale refs.
   - **Not forward**: don't stage it. If `${cur}` is an ancestor of `${rec}`, the submodule is behind — fast-forward it instead (`git -C <submodule-path> merge --ff-only "${rec}"`); the pointer then needs no commit at all. Otherwise the two have diverged — show the user both commits and ask how to reconcile them. `git diff --submodule=log -- <submodule-path>` shows a behind submodule as `(rewind)`, a diverged one as `<old>...<new>` listing commits on both sides (`<` and `>`), and `(commits not present)` when a commit is missing locally (fetch first).
   - **Not published** (the last command prints nothing): push the submodule's commit to its own remote first. Don't rely on `git -C <submodule-path> status` saying "up to date" — that only compares against the branch's upstream, which may be missing or stale. Never point the pointer at a SHA that doesn't exist on the submodule's remote, or others will fail to fetch it after cloning. Prefer a commit on a branch that will stay (the branch the superproject's branch is paired with, or the shared base branch): a commit only on a branch that is later rebased, squash-merged or deleted leaves the pointer dangling.
   - Use `git diff --submodule=log -- <submodule-path>` (or a plain `git diff` if `diff.submodule=log` isn't configured) to see which commits are involved, and mention them in the commit body if the range is non-trivial.
   - Stage and commit the pointer bump as its own logical change, separate from unrelated file changes: `git add <submodule-path>`.
   - Use a message like `chore: bump <name> submodule` for a single submodule, or `chore: bump <name1>/<name2> submodules` when bumping several at once; add a short parenthetical reason if useful. If the pointer bump is incidental to a larger docs/feature change, it's fine to fold it into that commit's message instead of forcing a separate commit — follow whatever pattern the repo's history already uses.

3. **A newly added submodule** (`git submodule add`; `A  <path>` in `--porcelain`) — there is no recorded pointer to compare against yet, so only the published check applies: `git -C <submodule-path> branch -r --contains HEAD --list 'origin/*'` must print something (fetch first). Commit `.gitmodules` together with the new path.

Whenever any submodule path shows up in `git status` — dirty, ahead, behind, or diverged — don't use `git add -A`/`git add .`: they stage the submodule's current HEAD as the pointer, which commits an unpushed pointer in case 1 and silently rewinds someone else's pointer when the submodule is behind. Name the files to stage, or use the `git add -A` form that excludes submodule paths (step 2), and stage a pointer only through case 2's checks.

The shell snippets in this file are exercised by `scripts/selftest.sh` (throwaway repos with submodules, every snippet run in both zsh and bash). After editing a snippet here, update the same snippet there and run it; it must end with `ALL PASSED`.

## Best practices

- Each commit should contain exactly one logical change
- Write in English by default: `add log aggregation script`, not a mixed-language description
- Use present tense, imperative mood: `fix parsing crash`, not `fixed parsing crash`
- Link issues: `Closes #123`, `Refs #456`
- Keep the description under 72 characters

## Git safety protocol

- Never modify git global/local config
- Never run destructive commands (e.g. `--force`, hard reset) without explicit request
- Never skip hooks (`--no-verify`) unless the user asks for it
- Never force-push: nothing in this workflow needs it. If the user explicitly asks, still never force-push the repo's default branch (find it with `git ls-remote --symref origin HEAD`; `refs/remotes/origin/HEAD` may not exist locally) or any branch the project treats as protected or shared
- If a commit fails due to hooks, fix the issue first and create a new commit (don't amend)
