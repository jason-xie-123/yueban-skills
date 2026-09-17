#!/usr/bin/env bash
#
# link-skills.sh — symlinks each skill under skills/ into .agents/skills/,
# making them visible to every agent client in this repo, with edits to the
# skills/ source taking effect immediately.
#
# Background: don't install externally-distributed skills with `npx skills add`
# (that's copy-based — editing the source won't take effect).
# The correct approach is a symlink: .agents/skills/<name> -> ../../skills/<name>
# This script is idempotent — after adding a new skill under skills/, just rerun it
# to fill in the missing symlink.
#
# Usage:
#   scripts/link-skills.sh             Create/fix all symlinks, and sync .gitignore
#   scripts/link-skills.sh --dry-run   Only print what would be done, don't change anything
#   scripts/link-skills.sh --force     If a real directory of the same name exists (likely a copy-based install), delete it and create a symlink instead
#   scripts/link-skills.sh --prune     Clean up stale symlinks under .agents/skills that point to skills/ but whose source no longer exists
#   scripts/link-skills.sh --no-gitignore  Skip .gitignore sync
#
# Symlinks themselves are not checked in (the skills/ source is authoritative), so each
# symlink needs to be ignored in .gitignore; this script automatically fills in any
# missing ignore lines (append-only, idempotent) — no manual upkeep needed.
#
set -euo pipefail

DRY_RUN=0
FORCE=0
PRUNE=0
SYNC_GITIGNORE=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    --prune)   PRUNE=1 ;;
    --no-gitignore) SYNC_GITIGNORE=0 ;;
    -h|--help)
      awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg (valid: --dry-run / --force / --prune / --help)" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

SRC_DIR="skills"
DST_DIR=".agents/skills"

if [ ! -d "$SRC_DIR" ]; then
  echo "Source directory $SRC_DIR/ not found, no skills to link." >&2
  exit 1
fi

mkdir -p "$DST_DIR"

# run CMD... — only prints in dry-run mode, otherwise executes
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

linked=0 fixed=0 ok=0 skipped=0 pruned=0 ignored=0
names=()

for src in "$SRC_DIR"/*/; do
  [ -d "$src" ] || continue
  name="$(basename "$src")"
  names+=("$name")
  link="$DST_DIR/$name"
  want="../../$SRC_DIR/$name"   # target relative to .agents/skills/

  if [ -L "$link" ]; then
    cur="$(readlink "$link")"
    if [ "$cur" = "$want" ]; then
      echo "✓ $name is already correctly linked"
      ok=$((ok + 1))
    else
      echo "↻ $name symlink points to the wrong target ($cur), rebuilding -> $want"
      run rm "$link"
      run ln -s "$want" "$link"
      fixed=$((fixed + 1))
    fi
  elif [ -d "$link" ]; then
    if [ "$FORCE" -eq 1 ]; then
      echo "⚠ $name is a real directory (likely a copy-based install), --force: deleting and replacing with a symlink"
      run rm -rf "$link"
      run ln -s "$want" "$link"
      fixed=$((fixed + 1))
    else
      echo "⚠ $name is a real directory under $DST_DIR (likely a copy-based install), skipped."
      echo "    Copy-based installs don't pick up source edits; confirm and rerun with --force to replace it with a symlink, or manually rm -rf '$link' and rerun."
      skipped=$((skipped + 1))
    fi
  elif [ -e "$link" ]; then
    echo "⚠ $name exists under $DST_DIR and is neither a directory nor a symlink, skipped: $link"
    skipped=$((skipped + 1))
  else
    echo "+ $name creating symlink -> $want"
    run ln -s "$want" "$link"
    linked=$((linked + 1))
  fi
done

# Clean up stale symlinks (pointing to skills/ but the source has been deleted)
if [ "$PRUNE" -eq 1 ]; then
  for link in "$DST_DIR"/*; do
    [ -L "$link" ] || continue
    target="$(readlink "$link")"
    case "$target" in
      ../../$SRC_DIR/*)
        if [ ! -e "$link" ]; then
          echo "✗ Cleaning up stale symlink: $(basename "$link") -> $target"
          run rm "$link"
          pruned=$((pruned + 1))
        fi
        ;;
    esac
  done
fi

# Sync .gitignore: make sure every symlink has an ignore line (append-only, idempotent)
if [ "$SYNC_GITIGNORE" -eq 1 ]; then
  gi="$REPO_ROOT/.gitignore"
  for name in "${names[@]}"; do
    entry="$DST_DIR/$name"
    if [ -f "$gi" ] && grep -qxF "$entry" "$gi"; then
      continue
    fi
    echo "+ .gitignore: adding ignore line for $entry"
    if [ "$DRY_RUN" -ne 1 ]; then
      printf '%s\n' "$entry" >> "$gi"
    fi
    ignored=$((ignored + 1))
  done
fi

echo
echo "Done: created ${linked}, fixed ${fixed}, already correct ${ok}, skipped ${skipped}, pruned ${pruned}, .gitignore entries added ${ignored}."
[ "$DRY_RUN" -eq 1 ] && echo "(this was a --dry-run, no changes were made)"
exit 0
