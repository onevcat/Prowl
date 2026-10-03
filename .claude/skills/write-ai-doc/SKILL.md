---
name: write-ai-doc
description: Create and maintain curated docs-ai/ records for substantial features and non-trivial, decision-shaping fixes (numbered entries with 000-plan.md before implementation and 001-action.md after). Do not use for reviews, audits, routine investigations, working notes, or status reports unless onevcat explicitly asks for a docs-ai/ record.
---

# Write AI Doc

`docs-ai/` is Prowl's curated product/design record, not a working-note log. A numbered
folder is reserved for a substantial feature or a non-trivial, decision-shaping fix, each
holding an RFC-like plan and an action log. Future humans and agents use it to answer "why
is it built this way?" — so entries must be selected deliberately and stay accurate against
the code. Read `docs-ai/README.md` for the index and intent.

## When to write one

Create a new entry only when the work is either:

- a substantial feature with an enduring product or architecture decision (for example, a
  new UI surface, subsystem, or multi-reducer behavior);
- a non-trivial fix whose root cause, design decision, or resulting behavior must guide
  future implementation.

Do **not** create an entry merely because the work is detailed, takes time, or produces useful
findings. Skip reviews, code or post-release audits, routine research/investigations and
debugging, status reports, test runs, pure formatting or dependency bumps, routine upstream
ports already recorded in the upstream ledger (`docs-ai/017-upstream-sync-process/upstream-ledger.md`), and docs-only changes. A user may explicitly request a record for an otherwise
non-qualifying task. When in doubt, do not write one.

## Workflow

### 1. New entry — plan first, before coding

1. Pick the next number: `ls docs-ai/ | sort` and take highest `NNN` + 1 (three digits).
2. Create `docs-ai/NNN-<kebab-slug>/000-plan.md` from the template below, `Status: Planned`.
   Write it as part of planning — background, goals, approach, alternatives — not as an
   afterthought.
3. Implement the work (normal branch/PR flow).
4. Write `001-action.md`: what actually happened, chronological, with PR/commit refs, the
   resulting key files, and deviations from the plan. Flip plan status to `Implemented`.
   Ship the docs in the same PR as the change when practical.

### 2. Follow-up on an existing entry (in-frame fix or extension)

1. Add the next-numbered file in the folder, e.g. `002-<topic>.md` (template below).
2. At the end of `000-plan.md`'s **Amendments** section append:
   `- Updated 2026-MM-DD: <one line> — see [002-<topic>.md](002-<topic>.md)`.
3. If the follow-up invalidates part of the plan or action text, correct that text in
   place (keep it truthful) and note the correction in the amendment.
4. Multi-PR entries (a plan with a slice table, e.g. `063`): each slice ships its own
   `00N-<slice>.md` amendment in the slice's PR, starting at `002`; write `001-action.md`
   once, when the last slice lands (or the entry is superseded), summarizing the slices.

### 3. Large pivot / redesign

If the change replaces the entry's approach rather than patching it, open a NEW numbered
entry, cross-link both directions, and mark the old plan `Status: Superseded by
[NNN-new-slug](../NNN-new-slug/000-plan.md)`.

## Templates

### 000-plan.md

```markdown
# NNN — <Title>: Plan

| | |
| --- | --- |
| **Status** | Planned \| Implemented \| Superseded by <link> |
| **Anchor date** | 2026-MM-DD |
| **Primary PRs** | #a, #b (fill in as they merge) |
| **Related** | [NNN-other](../NNN-other/000-plan.md), `docs/...` |

## Background
The product problem/pain and its context; for a fix, the observed symptom.

## Goals
Bullets. Add a **Non-goals** subsection when scope exclusion is a real decision.

## Design / Approach
The intended approach; name the key types/files it touches.

## Alternatives & decisions
Options considered and why the chosen one won. Record decisions, not just designs.

## Amendments
(append `- Updated 2026-MM-DD: ... — see [00N-topic.md](00N-topic.md)` lines here)
```

### 001-action.md

```markdown
# NNN — <Title>: Action Log

## Timeline
| Date | Change | Ref |
| --- | --- | --- |

## Outcome & current state (as of 2026-MM-DD)
What exists in code now; key files/types with repo-relative paths.

## Deviations from plan
Where reality diverged from 000-plan.md, or "None known."

## Open questions
Unverified claims, oddities worth revisiting, or "None."
```

### Amendment (002+)

```markdown
# NNN.00M — <Topic>

## Context
Why this follow-up happened.

## Change
What was done. | ## Refs: PR #x | ## Current state (optional)
```

## Writing rules

- English, factual, RFC-ish; prefer tables over prose for timelines. Plans are typically
  40–120 lines, actions 30–100 — long enough to be useful, short enough to be read.
- Every repo-relative file path you write must exist (verify with Glob/Grep before
  writing). Facts you can't verify belong under **Open questions**, not in prose.
- Reference fork PRs as `#123`, upstream PRs as `upstream #123`, files as inline code.
  Cross-link sibling entries with relative links.
- `docs-ai/` is the curated home for fork history plus fork-internal product, design, and
  operational docs. It is not a task journal.
  Numbered files are immutable history; **non-numbered** files inside an entry folder
  (e.g. `001-.../release-runbook.md`, `017-.../upstream-ledger.md`,
  `013-prowl-cli/contracts/`, `020-observability/runbook.md`) are living documents —
  update them in place when the process/contract they describe changes, and link them
  instead of duplicating their content.
- `docs/` (the user-facing agent manual) is separate: current behavior goes there,
  history/decisions/runbooks go in docs-ai. Never link `doc-onevcat/` — that directory
  was dissolved into docs-ai in 2026-07.
- The app module and scheme are `Prowl`; the app sources are in `App/Sources/...`. Numbered
  entries before 074 use the old paths (`supacode/...`); the path table is in `docs-ai/README.md`.
- After adding or renaming an entry, add/refresh its row in `docs-ai/README.md`'s index.
- Do not state build/test results you didn't produce.
