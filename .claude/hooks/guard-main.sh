#!/usr/bin/env bash
# PreToolUse hook (Bash): block commits and pushes to main.
# GitHub branch protection is not available on this private repo (free plan),
# so the CLAUDE.md rule "never commit directly to main" is enforced here.
set -uo pipefail

cmd=$(jq -r '.tool_input.command // empty')
root="${CLAUDE_PROJECT_DIR:-.}"
branch=$(git -C "$root" branch --show-current 2>/dev/null)

if [[ "$cmd" =~ (^|[;&|[:space:]])git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?commit ]] && [[ "$branch" == "main" ]]; then
  echo "Blocked: committing on main. Create a branch first (CLAUDE.md: never commit directly to main)." >&2
  exit 2
fi

if [[ "$cmd" =~ git[[:space:]]+push ]] && { [[ "$cmd" =~ [[:space:]:]main([[:space:]]|$) ]] || [[ "$branch" == "main" ]]; }; then
  echo "Blocked: pushing to main. Push a feature branch and open a PR." >&2
  exit 2
fi
exit 0
