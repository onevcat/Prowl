# 063.018 — Personal Workflow History: Plan

Status: Implemented locally. Authorized 2026-09-06.

## Scope and decisions

All workflow runtime data, including single-action tests, moves to
`~/.prowl/logs/workflow-runs/<root-name>-<root-hash>/YYYY-MM/<run-uuid>/`.
The canonical execution directory identifies a root. Symlink aliases share an identity;
separate clones and worktrees do not. Branch names and remotes do not affect identity.
Creation time fixes the UTC month. Metadata retains the original execution directory.
UUID lookup scans personal history independently of open repositories. Moving a project
never reassigns its old history. No migration, legacy reads, or old-data deletion is needed.
Team definitions, personal definitions, workspace metadata, and handoff storage do not change.

The owner confirmed these fixed product rules:

- Unpinned terminal runs expire 30 days after `finished_at`.
- A global 5 GiB soft budget can reclaim older terminal runs after a 24-hour diagnostic window.
- No preference adjusts these values or disables automatic cleanup.
- Manual cleanup uses the same eligibility rules, a candidate preview, and confirmation.
- Keep Run exempts a run. Live, recent, unknown, and corrupt records are protected.
- Only terminal runs can be exported as complete ZIP files. Exports are independent of retention.
- Agent reads require current task attribution and expose only assigned instructions, skills,
  and explicitly passed prior deliveries/action artifacts. A UUID alone grants no content access.

## Storage and safety

Use one injectable resolver and filesystem store rather than a database. Each run contains
its record, timeline, frozen definition, instructions, skills, outputs, and action attempts.
Use a global advisory lock for catalog mutations and a per-run occupancy lock. Locks use
close-on-exec descriptors. A live owner keeps occupancy through queued writes and action teardown.
Recovery may interrupt only known live states whose occupancy can be acquired; unknown state
is retained. Formal and Debug processes share this protocol.

Cleanup first inspects and reports candidates, then reacquires locks and rechecks status,
finish time, pinning, and physical containment. Delete complete run directories. Reject links
and special files; never traverse artifacts into unrelated files. Failed deletions are reported.
Export holds occupancy, checks the complete tree, writes a temporary ZIP, verifies it, and
publishes only a complete archive. Failure preserves the source and does not publish success.
Startup and completion request rate-limited background maintenance. Protected bytes and reasons
remain visible when the soft budget cannot be met. Cleanup never stops a script.

## Agent content transfer

Keep `workflow deliver -` as the ordinary text/JSON delivery boundary. Add and test a scoped
CLI read contract, including pane/run/invocation attribution, bounded content, and resource
identifiers issued by Prowl. Instructions must teach this route without home-directory grants.
Do not infer every runtime blocks external reads. Inspect actual sandbox behavior before adding
permissions. Explicit per-step staging is an option only for a demonstrated real-file need;
there is no automatic project staging or repository metadata modification.

## Delivery stages

1. Resolver, root identity, fixed run location, and global UUID lookup.
2. Retention selection, physical containment, occupancy, recovery, cleanup, and export.
3. Runtime lifecycle and scoped CLI content retrieval.
4. Existing Settings/history surfaces, Keep Run, export, preview, and current documentation.
5. Relevant nonzero workflow tests, CLI gates, `make check`, Debug build, isolated live acceptance,
   final review, explicit staging, commit, push, and a non-draft fork PR. No merge or release.

All filesystem tests use temporary storage and injected dates. Logic is tested before implementation.
UI verification uses a separate Debug instance and matching socket. Native script approval remains
separate from execution and is coordinated with the owner. Model demonstrations must be bounded and
announced. Validation evidence stays outside the repository; implementation results amend this topic.

## History UI

Settings → Agents → Workflows exposes Workflow History in the Execution History section.
The native macOS sheet uses system text styles, semantic foreground styles, and system colors.
Storage usage and retention rules precede the filter and run list; cleanup preview follows the list.
Rows show workflow, execution root, state, size, UUID, completion time, and protection reason.
Keep Run uses a checkbox; Export is enabled only for finished runs in known terminal states.
Action help explains effects, and Escape closes history or cancels the cleanup confirmation.
Cleanup opens a separate confirmation sheet with candidates, estimated space, and an irreversible-deletion warning.
The destructive Delete Runs action follows the preview; eligibility is checked again before deletion.

## Implementation boundaries

`WorkflowHistoryStorage` owns canonical identity, month placement, global UUID lookup,
physical containment, and advisory locks. `WorkflowHistory` owns eligibility, preview,
pinning, whole-run cleanup, and verified ZIP export. Runtime occupancy remains held
through action teardown. Transient action-process ownership records use the hidden
`.processes` catalog directory; per-run content remains self-contained.

Task content is in memory and bound to the reducer's current pane owner, run, and
invocation number. The CLI rechecks attribution after I/O. Resource IDs expose only explicitly
passed output/action paths and assigned skills. Directory resources return file lists;
256 KiB pages preserve binary data through base64 when needed. A task input cannot grant
run metadata or another role's instructions. Cancellation revokes access.

File access and Unix-socket access are separate sandbox permissions. Prowl uses the
existing CLI transport and does not change launch permissions for current/pick roles.
No default staging, global permission changes, or additional runtime packages are needed.
Debug-only data-directory injection isolates native acceptance from personal history.

### Simplified task reads

The owner approved using existing task identity instead of introducing read credentials.
`workflow read --run <UUID> --invocation <ordinal>` checks the caller pane against its
current assignment. There is no read token, token environment injection, or separate
credential lifecycle. Normal completion keeps the last assigned task readable until
reassignment, cleanup, or app exit. Cancellation revokes access. The existing `deliver`
delivery protocol retains its own validation.

This first release uses fixed retention settings and the existing filesystem/reducer
abstractions. No database, new authentication subsystem, or default staging is introduced.

## Validation results

The final simplified read contract passed all 286 tests in the 30 App workflow test
classes, 276 CLI unit tests, and 110 CLI integration tests. CLI build and executable
smoke checks passed. `make check` passed, including 146 repository script tests.
The final `make build-app` passed with no warnings.

Separate Debug instances confirmed built-in action execution, `test-action`, UUID
lookup after moving the execution root, and preservation of another process's
occupied run. Ordinary execution created no project-local runtime directory.
History, Keep Run, and cleanup preview received Debug visual verification.
An isolated sandbox probe distinguished external-file access from socket access;
allowing only the test socket enabled CLI transport. No model calls were used.

Native approval behavior is covered by reducer tests. Live human script approval
and model-driven instruction retrieval/output delivery remain manual acceptance
steps. Existing user App processes were not replaced or restarted.

## Review follow-up

Admission must remove its unpublished run directory on failure while preserving any
pre-existing run. Task reads must reject skipped and revoked activations. Log appends
must reject hard links, and process ownership files must use the history containment
checks. Complete the public read contract and socket/schema coverage. Successful history
operations must clear stale errors. Add focused regression tests before each logic fix;
these changes keep the existing storage and attribution design.

The five logic regressions were reproduced before their fixes and then passed.
Admission rollback now holds catalog coordination until publication or rollback and
never removes an existing UUID. Tests cover rejected input, initial-record failure,
and UUID collisions. Read tests reject skipped/revoked activations while retaining
normal-completion access. Filesystem tests preserve external hard-link targets and
reject a linked process registry. Reducer tests clear previous errors on successful
Keep/Export. Public read documentation now includes wire fields, pagination, and
errors; schema and mock-socket tests cover the contract.

The full workflow suite passed 293 tests. CLI unit tests passed 277 tests and socket
integration passed 111 tests. The change does not alter layout or toolbar controls;
the stale-error fix is verified through reducer state transitions.

`make check`, CLI build/smoke checks, and the final App build passed.

## Larger payloads and independent history metadata

Use fixed limits of 16 MiB for deliveries and action input/stdout, 4 MiB for stderr,
256 KiB content pages, 128 KiB launch prompts, and 64 MiB/8192 bundle entries.
Allow JSON transport overhead separately. Keep the 5 GiB soft history budget.

Persist a bounded `history.json` independently of the full `run.json`. Invalidate
old history metadata before replacing the record, then publish new metadata with
its record file identity. Missing metadata or a changed record remains protected;
no legacy reads or migration is added. History selection/export eligibility must
not load action outputs. Test large valid outputs through preview, export, and
expiry, plus interrupted publication and record changes.

Validation passed 313 App workflow/socket tests, 282 CLI unit tests, and 112 CLI
integration tests. Valid 1 MiB and 16 MiB JSON action outputs remain visible,
exportable, and eligible for expiry. Tests also cover missing/stale metadata,
failed record publication, full-size delivery escaping, independent stderr limits,
larger bundle limits, and 128 KiB prompts. CLI build/smoke and `make check` passed.
The JSON frame limit is 96 MiB + 64 KiB, allowing sixfold escaping plus envelope
fields while keeping application payload validation at 16 MiB.
The final App build passed with no warnings.
