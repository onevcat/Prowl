#!/bin/bash
# PreToolUse hook: block gh pr create unless it explicitly targets the fork.
# Exit 2 = block the command, exit 0 = allow.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only inspect gh pr create commands
if echo "$COMMAND" | grep -qE 'gh\s+pr\s+create'; then
  # Allow if explicitly targeting the fork (onevcat/supacode or onevcat/Prowl)
  if echo "$COMMAND" | grep -qE '(--repo|--repo=|-R)\s*onevcat/(supacode|Prowl)'; then
    exit 0
  fi
  cat <<EOF >&2
BLOCKED: gh pr create must explicitly target the fork.

Use:  gh pr create --repo onevcat/Prowl ...
Never target upstream (supabitapp/supacode).
EOF
  exit 2
fi

exit 0
