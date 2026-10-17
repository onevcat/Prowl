# 073.004 — Explicit workflow source when caller resolution fails

## Context

On 2026-10-18, a live shared daemon had one vnode descriptor for which both public
vnode queries returned `0 / ENOENT`. `ProcessDetection.openFilePaths(pid:complete:)`
marked the inventory incomplete, so `CodexDaemonThreadMapper` refused all caller
bindings. Other open rollouts contained enough evidence to match the observed panes,
but that does not make a partial inventory safe.

A private revoked-PTY experiment reproduced the error. It did not identify the live
descriptor or prove that every `ENOENT` means a revoked device. The public queries
do not return the vnode type on failure. FD numbers can be reused. Omitting the
newest thread's rollout can make the mapper bind an old thread to a pane that has
already switched threads. Keep the completeness guard.

## Decision

Use the existing explicit workflow source and step-token paths as a **workflow-only
fallback**. They complement caller resolution; they do not replace or repair it.

| Boundary | Evidence and behavior |
| --- | --- |
| Start | An explicit `--pane <UUID>` selects the `current` role. Admission checks that the pane exists, has the required agent, and is not owned by another run or dispatch. |
| Caller identity | Selecting a target does not establish that the command came from that pane. Do not promote an explicit source to a verified caller. |
| First task | Without a verified caller, the run has no self-initiated handoff. A message waits for the selected pane to become idle, then Prowl types it there. If the selected pane is the agent issuing `run`, that agent must end its turn instead of polling. |
| Return routing | The run holds role-to-pane bindings. Later messages return to that bound pane, independently of focus and caller lookup. This guarantees routing to the selected pane, not discovery of the initiating agent. |
| Read and deliver | Use the exact token-prefixed commands supplied with each task. An unresolved caller can use the task token. A resolved conflicting pane cannot use it to override its identity. |
| Lifecycle | Delivery tokens name one activation. Read access is limited to the role's latest assigned invocation and its granted resources. Skip, cancellation, and revocation remove access. Normal completion can retain the last task's read access. |

The pane must be selected independently, for example by the user in Active Agents,
or by a controller that created and retained the pane ID. Do not infer it from
inherited `PROWL_PANE_ID`, focus, cwd, or a heuristic session match in `prowl agents`.
If no reliable source is available, stop at source selection. The workflow token
arrives only after a run exists; it cannot bootstrap caller identity.

## Change

- Correct the bundled skills' blanket instruction to stop when caller is absent;
  describe this narrow exception and the required end-of-turn handoff.
- Document explicit-source start, fixed return routing, token use, and the limits in
  the CLI manual. Keep normal caller-based commands and the wire protocol unchanged.
- Add regression coverage for source selection without caller authority and stale
  tokens after a role receives another task. Preserve the incomplete-inventory guard.
- Validate with two real panes on the existing failed daemon: external start and
  start from the selected source itself, each with source → peer → source messages,
  scoped reads, and accepted deliveries. Do not restart the daemon or the live app.

## Alternatives

- A new caller fallback based on detected session IDs would reuse heuristic evidence
  and could assign commands to the wrong pane. It is not part of this design.
- Treating `--pane` as proof of self-identity would change an existing target selector
  into an authority claim and could expose the selected role's task to another caller.
- A new workflow mode or token protocol is unnecessary: the existing engine already
  supports explicit source selection and token-authorized participation.
- Profile `--no-daemon` remains useful for new sessions. It does not repair the
  existing shared daemon or preserve that session's execution mode.

## Verification

The existing app and shared daemon were not restarted. Two manually started sessions
shared the failing daemon. Each task checked its own thread ID and the absence of
`data.caller`. The source and peer used different threads; every final message returned
to the source's original pane and thread. The observer remained in a third pane.

| Live case | Result |
| --- | --- |
| External start (`DC569F68-772C-4631-8BFD-8895785FF46B`) | Source → peer → source; all three scoped task reads and deliveries succeeded. |
| Source-pane start (`A8DDDCBE-5F10-49D9-94F3-0D9045724840`) | `self_initiated` absent; the source ended its turn, received the first task, and completed the same three-step round trip. |
| Assigned resources (`4EA2038B-815F-4248-B4E3-9CBC3AB45A56`) | Same round trip; peer read the source's prior delivery through `resource-1`, and source read the peer's delivery through its own `resource-1`. Both verified the previous marker. |
| Stale token / wrong invocation | Scoped read and late delivery returned `TOKEN_INVALID`. |
| Unknown / omitted source | `TARGET_NOT_FOUND` / `SOURCE_REQUIRED`; neither started a run. |

All three runs completed. Their logs record nine deliveries with `source=token`;
no manual or forced delivery was used. The fixture performs no repository work.
Local replay inputs and receipts are retained under `build/caller-debug/workflow-fallback/`.

Automated regression coverage uses the existing source resolver, admission, run machine,
and coordinator. It checks that focus is not caller evidence, explicit selection does not
grant self-initiated authority or expose its token, returning messages target the bound
pane, and old tokens cannot read or deliver after reassignment. A valid token also cannot
override a resolved stranger pane. The five relevant Xcode test suites passed (68 tests).
`make check` and `make build-app` passed. Live acceptance exercised the existing runtime;
the rebuilt app was not installed into the running instance.

No runtime Swift change or new protocol was needed. The implementation change is the
bundled operational guidance and its regression coverage, not a new identity algorithm.

## Remaining limits

The live descriptor's original type and the event that caused its failure remain unknown.
Caller-scoped signals and ordinary dispatch completion still require caller resolution.
Pane closure and agent replacement are lifecycle failures, not reasons to redirect a
workflow to a guessed pane. This change does not claim to fix all of issue #911.
