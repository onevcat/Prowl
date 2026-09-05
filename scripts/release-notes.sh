#!/usr/bin/env bash
# Generate release notes for the next Prowl version.
#
# Usage: ./scripts/release-notes.sh [VERSION]
#
# Compares HEAD against the previous release tag, gathers commits and PR
# descriptions, and uses an LLM (Codex CLI) to produce user-facing release
# notes. Falls back to GitHub auto-notes if the LLM is unavailable.
#
# Output: build/release-notes.md
# The file can be reviewed and edited before running release.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

log() { echo "[release-notes] $*"; }
die() { echo "error: $*" >&2; exit 1; }

# ── Repository ───────────────────────────────────────────────────────────────

origin_repo_from_remote() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  [[ -z "$remote_url" ]] && return 1
  local repo
  repo="$(echo "$remote_url" | sed -E 's#^(git@github.com:|ssh://git@github.com/|https://github.com/)##; s#\.git$##')"
  [[ "$repo" == */* ]] && echo "$repo" && return 0
  return 1
}

REPO="${GH_REPO:-$(origin_repo_from_remote || true)}"
[[ -z "$REPO" ]] && REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[[ -z "$REPO" ]] && die "cannot determine GitHub repository"

# ── Version ──────────────────────────────────────────────────────────────────

if [[ -n "${1:-}" ]]; then
  VERSION="$1"
else
  VERSION="$(date +%Y.%-m.%-d)"
  suffix=1
  while git rev-parse "v$VERSION" >/dev/null 2>&1; do
    suffix=$((suffix + 1))
    VERSION="$(date +%Y.%-m.%-d).$suffix"
  done
fi

TAG="v$VERSION"

# ── Determine range ──────────────────────────────────────────────────────────

# If tag already exists, use it as the end point; otherwise use HEAD.
if git rev-parse "$TAG" >/dev/null 2>&1; then
  END_REF="$TAG"
else
  END_REF="HEAD"
fi

PREV_TAG="$(git describe --tags --abbrev=0 "$END_REF^" 2>/dev/null || true)"
if [[ -n "$PREV_TAG" ]]; then
  RANGE="$PREV_TAG..$END_REF"
else
  RANGE=""
fi

log "version: $VERSION"
log "range: ${RANGE:-<all commits>}"

# ── LLM generation ───────────────────────────────────────────────────────────

generate_llm_notes() {
  local range="$1"
  local raw_context
  raw_context="$(mktemp)"

  # Gather commit messages
  {
    echo "=== Commits ($range) ==="
    git log --pretty=format:'%s' "$range"
    echo ""
  } > "$raw_context"

  # Gather merged PR details (title + body)
  {
    echo ""
    echo "=== Merged Pull Requests ==="
    local pr_numbers
    pr_numbers="$(git log --pretty=format:'%s' "$range" | grep -oE '#[0-9]+' | tr -d '#' | sort -u)"
    for pr in $pr_numbers; do
      local pr_json
      pr_json="$(gh pr view "$pr" --repo "$REPO" --json title,body 2>/dev/null || true)"
      if [[ -n "$pr_json" ]]; then
        echo "--- PR #$pr ---"
        echo "$pr_json" | jq -r '"Title: \(.title)\nBody:\n\(.body)"'
        echo ""
      fi
    done
  } >> "$raw_context"

  # Gather diff stats
  {
    echo ""
    echo "=== Diff Stats ==="
    git diff --stat "$range"
  } >> "$raw_context"

  local prompt
  prompt="$(cat <<'PROMPT'
You are writing release notes for **Prowl**, a macOS app that runs multiple
coding agents in parallel, each in its own terminal tab.

Given the raw context below (commits, PR descriptions, diff stats), produce a
concise, user-facing changelog in Markdown.

## Rules

1. **Audience**: Prowl end-users (developers). They care about what changed in
   their day-to-day experience, not internal code structure.
2. **Include only user-visible changes**: new features, behavior changes, UX
   improvements, notable bug fixes. Skip pure refactors, test-only changes,
   CI tweaks, dependency bumps, and code-style changes unless they affect
   the user.
3. **Teach naturally**: when a change introduces a new shortcut, workflow, or
   setting, briefly explain how to use it (e.g. "Press ⌥⌘↩ to toggle
   Canvas view").
4. **Tone**: clear, professional, friendly. No marketing fluff, no emoji, no
   exclamation marks, no "we're excited".
5. **Format**:
   - Start with a one-line summary sentence of the release theme if there is a
     clear one; otherwise jump straight to the section.
   - Group items into sections using literal Markdown level-3 headings:
     `### New` for features/enhancements, `### Fixed` for bug fixes, and
     optionally `### Improved` for non-feature, non-bug enhancements. Omit a
     section if it has no items. Always use the `### ` heading syntax — never
     bold-paragraph forms like `**New**` or `**Fixed**`, and never `## `
     (which is reserved for the version header).
   - Use a flat bullet list (`-`) within each section.
   - Each bullet should be one or two sentences maximum.
   - End with nothing — no sign-off, no footer.
6. **Length**: aim for 3-8 bullets total. Merge trivial items. Omit if truly
   nothing is user-facing (output a single bullet: "- Internal improvements
   and stability fixes.").
7. **Language**: English only.
8. Output **only** the Markdown content. No preamble, no code fences.
9. Respect the release scope in the supplied context. Do not advertise hidden
   or deferred UI as available features. Keep maintainer diagnostics out of
   public notes. Use only the supplied context; do not run tools or edit files.
PROMPT
)"

  local notes_file
  notes_file="$(mktemp)"
  local generation_status=0
  {
    printf '%s\n\n%s\n' "$prompt" '--- RAW CONTEXT ---'
    cat "$raw_context"
    printf '\n%s\n' '--- END ---'
  } | codex exec --sandbox read-only --ephemeral --color never \
    --output-last-message "$notes_file" - \
    > build/release-notes-generation.log 2>&1 || generation_status=$?
  rm -f "$raw_context"

  if [[ "$generation_status" -eq 0 ]] && [[ -s "$notes_file" ]] \
    && [[ "$(wc -l < "$notes_file")" -ge 2 ]]; then
    cat "$notes_file"
    printf '\n'
    rm -f "$notes_file"
    return 0
  fi
  rm -f "$notes_file"
  echo "[release-notes] Codex generation failed (exit $generation_status); see build/release-notes-generation.log" >&2
  return 1
}

generate_fallback_notes() {
  local range="$1"
  if [[ -n "$range" ]]; then
    gh api "repos/$REPO/releases/generate-notes" \
      -f tag_name="$TAG" -f previous_tag_name="$PREV_TAG" \
      --jq '.body' 2>/dev/null || \
    git log --pretty=format:'- %s' "$range"
  else
    git log --pretty=format:'- %s' -20
  fi
}

# ── Validation ───────────────────────────────────────────────────────────────

# Lint a release-notes file against the CHANGELOG format used by Prowl-Site.
# Returns 0 on clean, 1 if violations were found (also prints them).
# Section headings must be `### New` / `### Fixed` / `### Improved` (level 3)
# so they sit one level below the `## [VERSION]` header that release.sh
# prepends. Bold paragraphs (`**Fixed**`) and `## Fixed` are both rejected:
# the site CSS targets `:global(h3)`, so anything else renders unstyled.
lint_release_notes() {
  local file="$1"
  local violations=()

  # Bold-paragraph section headers (whole-line)
  if grep -nE '^\*\*(New|Fixed|Improved)\*\*[[:space:]]*$' "$file" >/dev/null; then
    while IFS= read -r line; do
      violations+=("$line  (use '### …' instead of bold paragraph)")
    done < <(grep -nE '^\*\*(New|Fixed|Improved)\*\*[[:space:]]*$' "$file")
  fi

  # Level-2 section headers (collide with the version header)
  if grep -nE '^## (New|Fixed|Improved)[[:space:]]*$' "$file" >/dev/null; then
    while IFS= read -r line; do
      violations+=("$line  (use '### …' instead of '## …')")
    done < <(grep -nE '^## (New|Fixed|Improved)[[:space:]]*$' "$file")
  fi

  if [[ ${#violations[@]} -gt 0 ]]; then
    echo "release-notes format violations in $file:" >&2
    printf '  %s\n' "${violations[@]}" >&2
    return 1
  fi
  return 0
}

# ── Generate ─────────────────────────────────────────────────────────────────

NOTES_FILE="build/release-notes.md"
mkdir -p build

if [[ -n "$RANGE" ]]; then
  if command -v codex >/dev/null 2>&1; then
    log "generating release notes with LLM..."
    if generate_llm_notes "$RANGE" > "$NOTES_FILE"; then
      log "release notes generated by LLM"
    else
      log "LLM generation failed, falling back to GitHub auto-notes..."
      generate_fallback_notes "$RANGE" > "$NOTES_FILE"
    fi
  else
    generate_fallback_notes "$RANGE" > "$NOTES_FILE"
  fi
else
  generate_fallback_notes "" > "$NOTES_FILE"
fi

echo
echo "──── Release Notes ($VERSION) ────"
cat "$NOTES_FILE"
echo "──────────────────────────────────"
echo
log "saved to $NOTES_FILE"

if ! lint_release_notes "$NOTES_FILE"; then
  log "fix the headings above (use '### New' / '### Fixed' / '### Improved'),"
  log "then re-run this script or edit $NOTES_FILE before invoking release.sh."
  exit 1
fi

log "review and edit the file if needed, then run:"
log "  ./scripts/release.sh $VERSION"
