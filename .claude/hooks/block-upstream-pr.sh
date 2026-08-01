#!/bin/bash
# PreToolUse hook: block gh pr create against the true upstream, and require an
# explicit target so a missing --repo cannot default somewhere unintended.
# Exit 2 = block, exit 0 = allow.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if echo "$COMMAND" | grep -qE 'gh\s+pr\s+create'; then
  if echo "$COMMAND" | grep -qE '(--repo|--repo=|-R)\s*supabitapp/supacode'; then
    echo "BLOCKED: never open PRs against supabitapp/supacode." >&2
    exit 2
  fi
  if ! echo "$COMMAND" | grep -qE '(--repo|--repo=|-R)\s*[A-Za-z0-9._-]+/[A-Za-z0-9._-]+'; then
    echo "BLOCKED: gh pr create must name its target explicitly, e.g. --repo silvarbor/prowl." >&2
    exit 2
  fi
fi

exit 0
