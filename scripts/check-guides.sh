#!/usr/bin/env bash
#
# check-guides.sh — fail if any instructor-internal reference leaks into a
# student-facing surface.
#
# Anything published to Udemy (guide attachments) or synced to the public
# template repo must be self-contained: no path, handle, or phrasing that
# only makes sense inside the instructor repo. This lint is the tripwire.
#
# Usage:
#   scripts/check-guides.sh [PATH ...]
#
#   With no arguments it lints the instructor-repo scope (the four globs in
#   DEFAULT_SCOPE below). Pass explicit paths to widen or narrow it — e.g.
#   the template repo invokes `check-guides.sh .` to scan its whole tree,
#   and the fixture runner points it at one file at a time.
#
# Paths that don't exist are skipped (e.g. solutions/ before it's authored),
# so the same default scope works as the repo fills in.
#
# Exit status: 0 if clean, 1 if any forbidden token is found, 2 on misuse.

set -euo pipefail

# Instructor-repo scope. The template repo overrides this by passing `.`.
DEFAULT_SCOPE=(udemy/guides solutions bootstrap app)

# Forbidden tokens, matched case-insensitively as substrings.
#   - instructor-internal paths students never have
#   - the instructor's personal GitHub handle
#   - phrasing that implies a parallel repo or a fork relationship
FORBIDDEN=(
  'course-plan\.md'
  'issues/'
  'archive/'
  'ralph/'
  '\.agents/'
  'CLAUDE\.md'
  'AGENTS\.md'
  'CONTEXT\.md'
  'udemy/'
  'carlzxc71'
  'fork'
  'this repo'
  'the course repo'
)

# Join the token list into one alternation for a single grep pass.
pattern=$(IFS='|'; echo "${FORBIDDEN[*]}")

scope=("$@")
if [ ${#scope[@]} -eq 0 ]; then
  scope=("${DEFAULT_SCOPE[@]}")
fi

# Drop scope entries that don't exist yet, so a clean repo passes.
existing=()
for path in "${scope[@]}"; do
  if [ -e "$path" ]; then
    existing+=("$path")
  fi
done

if [ ${#existing[@]} -eq 0 ]; then
  echo "check-guides: nothing in scope to lint (skipped)."
  exit 0
fi

# This script *defines* the forbidden tokens, so a whole-tree scan (the mode the
# template repo runs, `check-guides.sh .`) would otherwise flag the lint on
# itself. Exclude its own source, and never descend into VCS internals — commit
# messages and packed refs are not a student-facing surface.
self=$(basename "${BASH_SOURCE[0]}")

# -r recurse, -I skip binary, -n line numbers, -i case-insensitive, -E regex.
if matches=$(grep -rInE --exclude-dir=.git --exclude="$self" "$pattern" "${existing[@]}"); then
  echo "check-guides: forbidden instructor-internal reference(s) found:"
  echo
  echo "$matches"
  echo
  echo "These must not ship to a student-facing surface. See CONTEXT.md"
  echo "(Internal reference) for the rule."
  exit 1
fi

echo "check-guides: clean — no internal references in scope."
exit 0
