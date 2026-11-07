#!/usr/bin/env bash
# PreToolUse hook (Bash): block commits and pushes to main.
# Complements GitHub branch protection: catches the mistake locally, before a
# commit lands on main and has to be moved to a branch.
set -uo pipefail

input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
# Check the branch where the command runs: the session's cwd (its own worktree
# for parallel sessions), not CLAUDE_PROJECT_DIR, which is the main checkout.
dir=$(jq -r '.cwd // empty' <<<"$input")
dir="${dir:-${CLAUDE_PROJECT_DIR:-.}}"
branch=$(git -C "$dir" branch --show-current 2>/dev/null)

if [[ "$cmd" =~ (^|[;&|[:space:]])git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?commit ]] && [[ "$branch" == "main" ]]; then
  echo "Blocked: committing on main. Create a branch first (CLAUDE.md: never commit directly to main)." >&2
  exit 2
fi

if [[ "$cmd" =~ git[[:space:]]+push ]] && { [[ "$cmd" =~ [[:space:]:]main([[:space:]]|$) ]] || [[ "$branch" == "main" ]]; }; then
  echo "Blocked: pushing to main. Push a feature branch and open a PR." >&2
  exit 2
fi
exit 0
