# 063.014 — Workflow Settings UI Refinement

## Status

Implemented and verified 2026-09-05 on `fix/workflow-settings-ui` after #761 merged. This
is an in-frame D1 follow-up: it revises the Settings information architecture and
presentation before R2b ships; it does not change the workflow DSL or runner. The decisions
below were reviewed against the existing macOS Settings patterns, Apple HIG list/detail
guidance, the `impeccable` Operate-mode guidance, and two independent UX/TCA reviews, then
grilled with the owner one decision at a time.

## Problem

#761 made every workflow setting available, but put the entire editor into each root-list
row: enablement, identity, Reveal, validation details, bind-mode overrides, role Profile
pickers, and a repeated Manage Profiles link. Repository workflows were also expanded into
the global page. The result is functionally complete but visually dense, hard to scan, and
uses implementation terms (`Bindings`, `Ask`, `Automatic`) without first explaining the
behavior they control.

The post-merge review also found two correctness boundaries:

- repository workflow enablement and bind-mode overrides use `repo/<id>`, so changing a
  control presented inside one repository would silently affect a same-id workflow in
  another repository; role Profile memory is already repository-qualified;
- `WorkflowStartCatalogItem` drops `WorkflowDefinition.icon`, so the Agents capsule uses a
  hard-coded workflow symbol even when YAML declares one.

## Product outcome

Settings should present workflows like a mature native macOS library:

- the first level is a calm, navigable summary;
- one workflow detail page owns configuration, diagnostics, run actions, and file actions;
- repository workflows live with their repository while reusing the same list rows and
  detail UI;
- user-facing copy describes what happens when Run is pressed, not the resolver's internal
  vocabulary;
- the Agents capsule stays a fast launcher and links to Settings for configuration.

## Decisions

### 1. Settings information architecture

The Agents sidebar order is:

1. **Profiles**
2. **CLI & Skills**
3. **Workflows**

Profiles and the CLI/skills installation are prerequisites for running workflows, so the
order teaches that dependency without explanatory chrome.

The global Workflows page contains only **Built-in** and **Your Workflows**. It no longer
scans, lists, or describes repository workflow sections. Empty Built-in is hidden rather
than showing “This build bundles no workflows yet.”

The page introduction is two short lines:

> Workflows coordinate agents through repeatable, multi-step tasks.
>
> Select a workflow to review its roles, run setup, and validation status.

A compact empty state appears only when the personal list is empty and offers **New
Workflow…** and **Ask an Agent…**. With content present, those actions remain visually
secondary at the end of the personal section.

### 2. Minimal workflow rows

A shared native navigation row renders only:

- the YAML SF Symbol, with the existing generic workflow symbol as fallback;
- name;
- monospaced id;
- description, capped so one verbose file cannot dominate the list;
- one text-and-symbol status;
- the system navigation affordance.

The row contains no toggle, file name/path, Reveal button, diagnostic list, run button,
bind-mode picker, role picker, or Manage Profiles link. The entire row navigates to the
detail page. Invalid, disabled, and superseded files remain navigable so Settings is always
a recovery surface.

List status vocabulary is:

- **Invalid · N errors** — the definition cannot run;
- **Disabled** — a deliberate neutral state, not an error;
- **Superseded** — another same-source definition wins;
- **Ready with N warnings** — runnable with diagnostics worth reviewing;
- **Ready** — enabled, valid, and effective.

Status never relies on color alone. Source precedence details belong in the detail page,
not in the list status line.

### 3. Workflow detail page

Global and repository parents push the same `WorkflowSettingsDetailView`, following the
existing Agent Profiles `NavigationStack` + TCA `StackState` pattern. The page uses a
native grouped Form rather than a custom hero/card layout.

The detail owns these sections:

1. **Workflow** — icon, name, id, description, source scope, and Enabled toggle.
2. **Run** — an explicit target and the existing workflow start path.
3. **Roles** — every declared role in author order, with Profile preference only where it
   applies.
4. **Run Setup** — whether Prowl presents the setup sheet before starting.
5. **Validation** — full diagnostics and source-precedence information; errors expand by
   default. A clean workflow needs only a compact Ready result.
6. **Source File** — path, Open Workflow, and Reveal in Finder.

The detail is not a YAML inspector: it does not reproduce the step graph or expose a GUI
workflow editor. Roles are shown because they teach the orchestration and hold local
Profile preferences; inputs remain the start sheet's responsibility.

If an external editor deletes or moves the file while its detail is open, the route remains
stable by file URL and changes into an honest unavailable state. It must not silently edit a
replacement row or crash.

### 4. Run Setup copy and disclosure

`Bindings`, bare `Ask`, and `Ready` are removed from user-facing configuration copy. The
section is named **Run Setup**, because the choice answers one question: whether Prowl shows
the setup sheet after Run is pressed.

The picker options and short inline explanations are:

| Option | Inline explanation |
| --- | --- |
| **Follow Workflow** | Uses the workflow author's default, including its current effective behavior. |
| **Always Review Before Running** | Shows the source pane, agents, inputs, and skipped steps before every run. |
| **Run Directly When Possible** | Starts immediately when every agent and required input is known; otherwise shows setup. |

For **Follow Workflow**, the UI names the current declared result (“Always reviews setup” or
“Runs directly when possible”) rather than exposing `bind: ask|auto`.

Detailed hover help explains the mechanism only on demand: a known launch choice can come
from a compatible Preferred Profile, workflow suggestion, or repository Recommended
Profile; `pick` roles, missing required inputs, an unresolved source, incompatible Profiles,
or an unusable CLI still present setup. Direct start never bypasses validation,
compatibility checks, or admission.

This is an intentional three-level information hierarchy:

1. the control label states the user's decision;
2. one sentence states the visible outcome;
3. hover help explains resolver details.

### 5. Roles and Profile preferences

The Roles section lists every role with its YAML name and a short behavioral explanation:

- `current`: “Uses the pane that starts this workflow.”
- `pick`: “Choose an existing agent when starting.”
- `launch`: “Prowl launches a new agent”, including tab/split, direction, and background
  behavior when useful.

A `launch` role has a **Preferred Agent Profile** picker. Its empty choice is **Choose
Automatically**, not “Ask at start”: Prowl first tries the workflow suggestion and the
repository's Recommended Profile, and asks only when it cannot resolve a compatible choice.
A selected Profile remains a preference, not an unsafe hard binding; every run revalidates
it and falls back safely when it was removed, disabled, or became incompatible.

The visible row stays compact (for example, `counter  [Claude Review ▾]`) with one short
behavior line. Compatible-agent requirements, suggestion/fallback order, and rejection
reasons live in menu rows and hover help. **Manage Agent Profiles…** appears at most once
at the end of the Roles section.

### 6. Explicit run targets

There is no Run button in the first-level list. A global workflow is not bound to one
repository, so a context-free row action would be ambiguous and visually noisy.

The detail page offers **Run in _<current worktree>_** plus a native menu for other legal
worktrees and **Run with Options…**. A repository workflow lists only worktrees belonging
to that repository. With no legal worktree, the action is disabled and the page explains
that a worktree must be opened first.

Run delegates through Settings to `AppFeature`, activates the main window, and sends the
existing `openWorkflowStart(workflowKey:worktreeID:sourceSurfaceID:forceSheet:)` action.
Settings never calls the coordinator or creates a run itself. `forceSheet: false` preserves
a legal direct start; **Run with Options…** uses `forceSheet: true`. C2's start context,
CLI preflight, role resolution, admission, and failure semantics remain the single path.

### 7. Source-file actions and automatic validation

**Open Workflow** uses `NSWorkspace.open` / the existing open-URL dependency, honoring the
user's macOS association for YAML files. **Reveal in Finder** is a secondary folder-icon or
overflow action with a tooltip. The selectable path appears only in detail.

**New Workflow…** creates the validated starter in the current scope and opens it directly:

- global page → `~/.prowl/workflows`;
- repository section → `<repository root>/.prowl/workflows`.

Built-in definitions may be opened or revealed but are explicitly marked **Read-only**.
There is no separate Validate button: the existing file watcher revalidates after every
save, and the detail says **Validated automatically**. A manual button that merely repeats
the live scan would add ceremony without a new capability.

### 8. Repository Settings

Repository workflows appear directly in a standalone **Workflows** Form section immediately
after the existing **Agents** section. This preserves the owner's current preference for a
visible list and defers the broader repository Settings reorganization.

The section reuses the global page's minimal row and the shared detail page. It includes the
repository-scoped New Workflow and Ask an Agent actions. A repository definition that wins
over a personal definition says in detail:

> Overrides your personal workflow in this repository.

The global page does not report repository override state because it has no active
repository context.

### 9. Repository-qualified local preferences

Repository workflow controls must affect only the repository whose Settings page contains
them. Enabled and Run Setup keys therefore become repository-qualified, aligned with the
existing role Profile memory scope:

- bundle and user keys remain stable;
- repository keys include the canonical repository root and workflow id.

The runtime list, GUI catalog, start context, and admission all derive this key from the same
`WorkflowRunScope`; no View constructs it. Legacy pre-release `repo/<id>` values are
migrated across the repositories registered at migration time, then removed, so the visible
state does not unexpectedly reset while future edits become repository-local. The exact
serialized spelling remains an implementation detail unless it is already exposed by the
settings reference; tests pin migration and lookup behavior.

This correction lands before R2b ships. It is not deferred: presenting a project-local
control backed by cross-project state is misleading.

### 10. Agents capsule boundary and workflow icons

The 280-point Agents capsule remains a quick launcher:

- workflow row: YAML icon, name, short description, one-click Run;
- trailing menu: **Run with Options…** and **Show Details in Settings…**;
- invalid row: YAML icon when parseable, error summary, and a route to its Settings detail.

The capsule does not embed Profile pickers, switches, paths, diagnostic lists, or the full
Settings detail. It shares focused components and presentation only: `WorkflowIcon`, status
projection, compact summary, and start/detail routing.

`WorkflowStartCatalogItem` carries `WorkflowDefinition.icon`; its assembler and tests pin
the value. Settings lists/details and the capsule use one safe icon renderer with a generic
fallback.

## Implementation shape

The implementation should preserve one discovery/validation source while splitting the
presentation load:

- introduce a compact list projection and a detail projection instead of making every root
  row carry all diagnostics and role candidates;
- parameterize workflow Settings state by global or repository scope;
- global scan watches bundle/user only; repository scan reads bundle/user/repository for
  precedence but publishes and watches only that repository's relevant list and files;
- let global `WorkflowsSettingsFeature` and `RepositorySettingsFeature` own their TCA stack
  routes to the shared detail feature;
- update an open detail from live scans by stable file URL; retain a missing-file state when
  no row remains;
- keep local preference writes field-wise in `@Shared(.userGlobalSettings)` so concurrent
  Profile edits cannot be clobbered;
- route Run and Settings navigation through delegates; do not resolve app-global state in
  leaf Views.

The exact type decomposition may be adjusted during test-first implementation, but the
ownership boundaries above are product decisions.

## Test plan

Start with failing tests for:

- Agents sidebar order;
- compact list status precedence and all invalid/disabled/warning/superseded states;
- global catalog excludes repository rows and repository catalog contains only its own rows;
- global and repository navigation push the same detail behavior;
- every role source gets correct concise presentation; only launch roles get Profile choices;
- Run Setup labels/effective explanations and field-wise persistence;
- repository-qualified enable/Run Setup lookup and legacy-key migration;
- run target filtering and delegation to the existing start action, including force-sheet;
- Open, Reveal, global/repository New Workflow, and automatic reload;
- a detail whose file changes, becomes invalid, or disappears while open;
- YAML icon propagation into `WorkflowStartCatalogItem` and capsule presentation;
- direct navigation from the capsule to the exact Settings detail.

## Verification and delivery

- Run focused reducer/catalog/start-context tests while implementing.
- Run `make check`, `make test`, and `make build-app` on the final head.
- Because the Agents toolbar popover changes, follow the 061 visual gate: inspect a Debug
  build at normal and constrained widths in Normal, Shelf, and Canvas modes; verify YAML
  icons, Run, the trailing menu, Settings deep-link, keyboard navigation, tooltips, and
  Accessibility labels.
- Inspect global and repository Settings with empty, typical, invalid, disabled, warning,
  superseded, many-role, and externally-deleted files.
- Update `docs/components/workflows.md`, `docs/components/settings.md`, and the Settings
  reference where the preference scope is described.
- Record implementation and observed verification in this amendment before merge.

## Implementation result

The implementation follows the ownership above with these concrete boundaries:

- `WorkflowSettingsScope` parameterizes one shared settings reducer; the global client scan
  publishes bundle/user entries, while a repository instance publishes only its own compact
  rows and filters Run targets to that repository.
- `WorkflowSettingsDetailFeature` is pushed through reducer-owned `StackState`. Live scans
  replace its row by stable file URL; a removed file leaves the route present and inert. The
  watcher belongs to the enclosing navigation host, so pushing the detail does not stop
  automatic validation.
- `WorkflowPreferenceKey` is the single enablement/Run Setup key constructor for catalog,
  CLI list, start catalog, and run admission. Repository keys use a standardized root path;
  the app migrates legacy `repo/<id>` settings when its repository set becomes known.
- Settings Run delegates to `AppFeature.openWorkflowStart(...)` with an explicit worktree.
  The main window is surfaced first, and no coordinator or admission logic is duplicated.
  If that explicit worktree disappears, the run is refused rather than redirected to a
  different current worktree.
- `WorkflowStartCatalogItem` now carries source URL, scope, and YAML icon. The Agents
  capsule renders that icon and its overflow menu deep-links to the exact global or
  repository detail.
- User documentation now describes the compact index, repository placement, detail
  sections, Run Setup vocabulary, explicit target, and source-file behavior.

Verification on the final implementation:

- `make check` passed (changed-file format, full Swift format lint, SwiftLint, and 82 support
  tests).
- `make test` passed 3,058 app tests plus 2 additional tests with zero failures.
- `make build-app` completed a Debug build with zero errors and zero warnings.
- Focused workflow/settings/repository suites passed 94 tests during implementation and 51
  tests after the final domain/UI refinements.
- Debug visual checks covered the global index at normal and minimum Settings widths, a
  typical detail page, the repository Settings Workflows section/empty state, YAML icons,
  invalid rows, the overflow menu, and exact Settings deep-link. The same Agents popover was
  exercised in Normal, Shelf, and Canvas. Accessibility inspection confirmed navigation
  rows, Run, Profile, source-file, and overflow actions; the menu indicator was hidden after
  the first pass exposed a duplicate chevron.

## Non-goals

- A GUI YAML editor, workflow step graph, history browser, or V2 DSL work.
- Changing runner semantics, profile compatibility, or start admission.
- Turning the Agents capsule into a nested Settings interface.
- The broader Repository Settings information-architecture refactor.
- Decorative custom materials, colors, or non-native navigation controls.
