#!/usr/bin/env python3
"""Static checks for the skills under skills/ (no dependencies, no network).

  python3 scripts/check-skills.py [skills-dir]

Checks, per skills/<name>/SKILL.md:
  1. front matter: starts with `---`, closes with `---`, has `name` (equal to the directory name) and a non-empty `description`;
     every single-line scalar in it must parse as written: quotes closed (an apostrophe in a single-quoted value is written twice),
     and an unquoted value must not contain `: ` or ` #`, which a YAML parser reads as a mapping or a comment;
  2. relative Markdown links (`[text](path)`, `#anchor` ignored) point at files that exist; fenced code blocks and inline code
     are skipped, they hold examples;
  3. a skill that uses the `<ROADMAP>` placeholder defines it (a line containing "`<ROADMAP>` 指") and no file of that skill
     (SKILL.md, templates, scripts) writes a bare `ROADMAP.md` outside the default path `openspec/changes/ROADMAP.md`;
  4. scripts/*.sh and skills/*/scripts/*.sh pass `bash -n`.

Exit status is 1 when any check fails.
"""
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILLS = os.path.join(ROOT, sys.argv[1] if len(sys.argv) > 1 else 'skills')
DEFAULT_ROADMAP = 'openspec/changes/ROADMAP.md'

problems = []


def problem(path, message):
    problems.append(f'{os.path.relpath(path, ROOT)}: {message}')


def front_matter(text):
    match = re.match(r'---\n(.*?)\n---\n', text, re.S)
    return match.group(1) if match else None


def key_value(block, key):
    match = re.search(rf'^{key}:[ \t]*(.*)$', block, re.M)
    return match.group(1).strip() if match else None


def strip_code(text):
    """The text without fenced code blocks and inline code."""
    text = re.sub(r'^```.*?^```', '', text, flags=re.S | re.M)
    return re.sub(r'`[^`\n]*`', '', text)


def scalar_problem(value):
    """Why a single-line YAML scalar would not parse as written, or None. Block scalars and flow collections are not judged."""
    if not value or value[0] in '>|[{&*!%@`':
        return None
    if value[0] == "'":
        i = 1
        while i < len(value):
            if value[i] == "'":
                if value[i + 1:i + 2] == "'":
                    i += 2
                    continue
                return None if value[i + 1:].strip() == '' else 'text after the closing single quote'
            i += 1
        return 'single-quoted value is not closed (an apostrophe inside must be written twice)'
    if value[0] == '"':
        i = 1
        while i < len(value):
            if value[i] == '\\':
                i += 2
                continue
            if value[i] == '"':
                return None if value[i + 1:].strip() == '' else 'text after the closing double quote (escape inner quotes with a backslash)'
            i += 1
        return 'double-quoted value is not closed'
    if ': ' in value or ' #' in value:
        return 'unquoted value contains ": " or " #", which breaks YAML parsing'
    return None


def check_skill(skill_md):
    directory = os.path.dirname(skill_md)
    text = open(skill_md, encoding='utf-8').read()
    block = front_matter(text)
    if block is None:
        problem(skill_md, 'front matter is missing or not closed by a second `---` line')
        return
    name = key_value(block, 'name')
    if name != os.path.basename(directory):
        problem(skill_md, f'name `{name}` differs from the directory name')
    description = key_value(block, 'description')
    if not description:
        problem(skill_md, 'description is missing or empty')
    elif description in ('>', '|', '>-', '|-', '>+', '|+') and not re.search(rf'^description:.*\n[ \t]+\S', block, re.M):
        problem(skill_md, 'block-scalar description has no indented content')
    for key, value in re.findall(r'^([A-Za-z][\w-]*):[ \t]*(.+)$', block, re.M):
        message = scalar_problem(value.strip())
        if message:
            problem(skill_md, f'front matter `{key}`: {message}')
    for link in re.findall(r'\]\(((?!https?:|mailto:|#)[^)\s]+)\)', strip_code(text)):
        target = os.path.normpath(os.path.join(directory, link.split('#')[0]))
        if not os.path.exists(target):
            problem(skill_md, f'relative link `{link}` points at a file that does not exist')
    if '<ROADMAP>' in text:
        if '`<ROADMAP>` 指' not in text:
            problem(skill_md, 'uses <ROADMAP> but never defines it (expected a sentence containing "`<ROADMAP>` 指")')
        for path in sorted(glob.glob(os.path.join(directory, '**', '*'), recursive=True)):
            if os.path.isfile(path) and os.path.splitext(path)[1] in ('.md', '.js', '.sh'):
                bare = re.sub(re.escape(DEFAULT_ROADMAP), '', open(path, encoding='utf-8').read())
                if re.search(r'ROADMAP\.md', bare):
                    problem(path, 'writes a bare ROADMAP.md although the skill defines <ROADMAP>; use <ROADMAP> or the default path')


for skill_md in sorted(glob.glob(os.path.join(SKILLS, '*', 'SKILL.md'))):
    check_skill(skill_md)

for script in sorted(glob.glob(os.path.join(ROOT, 'scripts', '*.sh')) + glob.glob(os.path.join(SKILLS, '*', 'scripts', '*.sh'))):
    result = subprocess.run(['bash', '-n', script], capture_output=True, text=True)
    if result.returncode != 0:
        problem(script, 'bash -n failed: ' + result.stderr.strip().splitlines()[0])

if problems:
    print('\n'.join(problems))
    print(f'\n{len(problems)} problem(s)')
    sys.exit(1)
print('skills ok')
