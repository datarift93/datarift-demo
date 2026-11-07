#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): lint the file the agent just changed.
# Exit 2 sends the errors back to the agent so it fixes them right away.
set -uo pipefail

file=$(jq -r '.tool_input.file_path // empty')
[[ -z "$file" || ! -f "$file" ]] && exit 0

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
rel="${file#"$root"/}"

case "$rel" in
  node_modules/*|.next/*) exit 0 ;;
  *.ts|*.tsx|*.mts|*.js|*.mjs)
    out=$(cd "$root" && pnpm exec eslint --max-warnings=0 "$rel" 2>&1) ;;
  pipeline/*.py)
    out=$(cd "$root/pipeline" && uv run --quiet ruff check "${rel#pipeline/}" 2>&1 \
      && uv run --quiet ruff format --check "${rel#pipeline/}" 2>&1) ;;
  *) exit 0 ;;
esac

if [[ $? -ne 0 ]]; then
  echo "Lint failed for $rel:" >&2
  echo "$out" >&2
  exit 2
fi
exit 0
