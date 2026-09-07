# 063.012 — V1 DSL Boundary Observations (input for V2)

## Status

Recorded 2026-09-02 from a hands-on exploration session run by onevcat against the live
post-C2 build (#752 merged). Method: a series of small disposable workflows
(`~/.prowl/workflows/demo-*.yaml`, not preserved) designed to probe specific limits, each
with predictions written down before the run and verified against `log.md`, the outputs
ledger, and the participating agents' session logs. This note is the durable artifact;
it exists to feed the V2 items reserved in [dsl-spec §12](dsl-spec.md#12-reserved-for-v2)
with observed evidence rather than speculation.

Evidence runs referenced below (all in `Prowl/.prowl/workflow-runs/`):

- `49DE6E89` — `demo.guess-number`: 3 launch roles, verdict-driven `repeat`, shared-output
  broadcast, prompt-level conditional ("winner summarizes"). Completed in 3 rounds.
- `CBD43E65` — `demo.parallel-probe`: expect-less fork of two workers, ordered join,
  aggregation, `repeat {max: 1}` as a poor-man's `if`. Completed; loop skipped pre-entry.

## Findings

### F1 — By-reference output passing costs agents nothing; the real gap is human-facing surfaces

Agent→agent handover via `{{ deliveries.<name>.path }}` was frictionless in every experiment:
a receiving agent reads the file as its first action, and the guess-number players
demonstrably consumed each other's rounds through the shared file. The one place the
"no inlined output text" rule (§6) actually bites is a surface where nobody can
dereference a path: the `notify` bell. "Put the computed number in the notification"
is inexpressible.

**V2 input:** if this is ever opened, open it narrowly — e.g. a sanitized, length-capped
`deliveries.<name>.firstline` allowed in `notify` only, passed through the existing
rendered-text validation. The agent→agent case needs nothing.

### F2 — A poor-man's `if` already exists: `repeat { max: 1, until: <cond> }`

Because `until` is evaluated before entry, this shape is exactly `if !cond { body }`.
Verified in `CBD43E65`: verdict `clean` → `'until' already satisfied; loop skipped`,
zero invocations minted for the body.

**V2 input:** `when:` (reserved) is still worth having for readability and for guarding
individual steps, but it can reuse existing machinery: a guarded step that does not run
is semantically a skipped step, so the §5 Skip rule's missing-output consequence analysis
(non-optional consumer → run ends) transfers as-is.

### F3 — Fork is already free; ordered join is expressible; join-any is the missing primitive

Observed in `CBD43E65`:

- Two expect-less `launch` steps executed within the same second — the runner advances
  immediately, so both workers ran wall-clock concurrently (self-reported work windows
  overlapped by ~22 s, confirmed by the aggregator).
- Sequential `message` + `expect` steps after the forks form a working join-all: the
  earlier-finished worker simply idles until its turn.

What cannot be expressed is a race ("first delivery wins, cancel the rest"). The pieces
mostly exist: the dispatch store is per-surface (concurrent activations on different
panes are structurally fine), and token revocation already implements "abandon an
activation". Missing: a runner phase that waits on several activations at once, branch
cancellation semantics, and two validator rules — concurrent branches must produce
disjoint output names (or latest-wins becomes racy), and a branch must not reference a
sibling branch's outputs before the join point.

**V2 input:** the reserved `wait: { all: […] }` covers join-all; consider
`wait: { any: […] }` with loser cancellation as the second half. The serialization
guarantee behind the `<name>.md` latest view must be preserved per name.

### F4 — Idle gating measures turn state, not task state (the backgrounding blind spot)

The most interesting finding. In `CBD43E65` the counter worker put `sleep 15` into a
background task; its turn ended, the surface read as genuinely idle, and the join
message ("deliver your findings now") was injected mid-task — 29 s before the work
actually finished. The system absorbed it: the runtime queued the injected line, the
agent finished its work first, then delivered; token correlation kept the delivery on
the right activation. But the contract "an activation is only opened against an idle
agent" (§5) silently means *turn-idle*, not *task-idle* — an agent that backgrounds
work looks idle, and a less careful agent could have answered the early "deliver now"
with an empty result.

**V2 input:** adjacent to the reserved `turn-start` signal. Options, cheapest first:
document the phrasing convention for join prompts ("deliver when your work is complete",
never "now"); teach the idle gate about pending background tasks where the runtime
exposes them; or lean on the reserved observe mode (`expect.status: idle` + `capture`)
for joins that must not perturb the worker at all.

### F5 — Fire-and-forget steps advance instantly and mint ordinals; there is no wait-without-delivery

An expect-less `message`/`launch` completes the step the moment injection/launch
succeeds (run `7D74F4EA` ended while its helper was still composing; the forks in
`CBD43E65` occupied ordinals 1–2 without ever waiting). The only way to make the run
wait for a role is to demand a delivery. A "wait until idle, capture nothing" step is
inexpressible — same gap the reserved `expect.status: idle` addresses.

### F6 — Prompt-level conditionality works, but it is a contract, not a guarantee

Two branch-shaped behaviors were pushed into prompts and both executed correctly with a
strong model: "winner writes the summary, loser congratulates" (`49DE6E89`, both wrap
steps ran, the agents implemented the branch), and "do the work now but deliver only
when asked" (the fork contract in F3/F4). These are the patterns `when:` and real joins
would harden; until then the DSL's determinism ends at the prompt boundary and the
watchdog/timeout machinery is the only backstop.

### F7 — Smaller observations

- **Pre-loop seed delivery.** A loop body whose first step references
  `{{ deliveries.<name>.path }}` needs a producer before the loop to satisfy dominance
  checking; guess-number seeded it with an opening delivery (verdict `ready`) that also
  burned one of the four verdict slots. Worth documenting as an authoring pattern
  (D1 skill), and worth remembering as pressure on the 2–4 verdict cap.
- **Shared output name as broadcast.** Several steps delivering to one name
  (latest wins) served as the "referee speaks aloud" channel and read naturally.
  Legitimate pattern; F3's disjointness rule must only constrain *concurrent* producers.
- **`repeat` YAML shape is a foot-gun.** `steps` is a sibling of `repeat:`, not nested
  inside it; the validator catches the mistake clearly (`unknown_key` + `missing_key`),
  but the shape surprises on first contact. D1's authoring skill should call it out.
- **Unused launch roles validate clean.** A declared `launch` role with no referencing
  step produces no diagnostic. Harmless, but a lint warning would catch leftover roles
  after step edits.
- **Watchdog nudge observed live** (`49DE6E89`, setup step, 33 s): state-driven
  supervision worked as specified; no false nudges during 12 gated injections across
  3 rounds.

## Out of scope

These are observations, not commitments; the V2 surface itself stays as reserved in
dsl-spec §12. No V1 behavior observed here was judged a bug — every experiment matched
the spec once the spec was read carefully.
