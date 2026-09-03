# 063.013 — Settings › Workflows, `workflows.md`, and CLI Reachability (D1, rest)

## Status

Drafted 2026-09-04 on `feat/workflow-settings-d1`; implemented and opened as
[#761](https://github.com/onevcat/Prowl/pull/761) the same day. D1's authoring skill shipped ahead of the
slice as `prowl-workflow` (#754); this record covers the remaining D1 scope from the
[release plan](release-plan.md): the Settings › Agents › **Workflows** page, the agent-facing
manual `docs/components/workflows.md`, and the CLI reachability status deferred from C0
([002](002-settings-agents-group.md)). The design was frozen by [000-plan](000-plan.md) (UI
section: "Settings information architecture", "CLI reachability status"; slice table row D1)
and by C2's decision 5 ([011](011-c2-start-sheet.md)); the decisions below fill the gaps the
plan left to implementation.

## Product contract

R2a/C2 left every workflow *setting* hidden: `disabledWorkflowIDs` had no toggle, the tri-state
bind-mode override was written only by the sheet's "Don't ask again", remembered role
bindings could be corrected only through "Run with Options…", validation errors were visible
only to `prowl workflow validate`, and a user whose `prowl` could not reach the app saw a
healthy-looking Settings page. D1 closes that:

- **Settings › Agents › Workflows** (between Profiles and CLI & Skills, per the plan's IA):
  - a CLI dependency banner at the top — Install inline when `prowl` is not installed, the
    socket failure reason when Prowl is not listening (no Install for that);
  - **Built-in**, **Your Workflows** (`~/.prowl/workflows`), and **Repositories**
    (`<root>/.prowl/workflows` of every open repository that has files) lists;
  - per row: enable checkbox (`disabledWorkflowIDs`, keyed `<scope>/<id>`), icon/name/id/
    description, validation status with the diagnostics (`line:column message code`), an
    "Overridden by <file>" / "Overridden in <repository>" note when another definition wins
    the id, **Reveal**;
  - per row with `launch` roles: the **Bindings** picker (Follow file / Always ask /
    Automatic — C2's tri-state) and one profile picker per launch role showing the remembered
    profile (editable: pick a qualifying profile or "Ask at start"), with **Manage Profiles…**
    jumping to Settings › Profiles;
  - **New Workflow…** writes a validated starter file to `~/.prowl/workflows/` and reveals it;
    **Ask an Agent…** hands over a copyable prompt (localized like Help › Ask Agent About
    Prowl) that points the agent at the bundled `prowl-workflow` skill and manual;
  - the lists refresh when the watched directories change, so editing a file in an editor
    updates its validation status without leaving Settings.
- **Settings › Agents › CLI & Skills › Connection** gains a **Status** row: Listening /
  Not running / failed with the reason (another instance, permissions, path too long, …).
- **Workflow start preflight**: the start sheet's banner and the immediate-start gate use the
  same reachability signal — a socket failure blocks Run with its reason.
- **`docs/components/workflows.md`**: the manual page for the feature (what a workflow is,
  sources, entry points, the start sheet, the status center, Settings, run directory, CLI
  pointers), indexed from `docs/README.md`; `settings.md`, `settings-fields.md`, `cli.md`,
  and the C2 entry-point pages cross-link it.

## Decisions taken for implementation

1. **Reachability is a status the server owns, read through a dependency client.**
   `CLISocketServer` publishes `CLIServiceStatus` (`stopped` / `listening(path)` /
   `failed(CLIServiceError, path)`) through a main-actor publisher; `CLIServiceStatusClient`
   exposes `current`. Settings reads it when the page appears (as `refreshCLIInstallStatus`);
   the workflow start context assembly reads it for the preflight. No stream is wired: the
   status changes only at start and quit in V1, and a stream nobody consumes is dead weight.
2. **The Workflows page is a TCA child of `SettingsFeature`** (`WorkflowsSettingsFeature`),
   created on selection and torn down on leaving it — the `AgentSkillsFeature` shape — so
   the directory watcher is cancelled with the page. Row derivation is a pure builder
   (`WorkflowSettingsCatalog`) over discovery entries + `UserGlobalSettings`, tested without
   the filesystem; the filesystem scan, template creation, Reveal, and watching live in
   `WorkflowSettingsClient`, assembled in `WorkflowSettingsComposition` from the same runtime
   snapshot the start client reads, so both use the same validation inputs (bundled skill
   ids, agent catalog, probes, profiles).
3. **Settings writes workflow fields field-wise into `@Shared(.userGlobalSettings)`**, never
   replacing the whole struct: the Profiles page may be editing `agentProfiles` in another
   window state, and a whole-struct write from here would clobber it.
4. **Repository workflows are listed per repository, only for repositories that have files.**
   An empty section per open repository would be noise; a single note says where files go.
   The disabled key stays `<scope>/<id>` (B1's contract), so the same id in two repositories
   shares one toggle — documented, not "fixed": a per-repository key would change the CLI's
   `list` semantics, which is out of D1's scope.
5. **Remembered bindings are editable here because nothing else can reset them.** The picker
   offers every enabled profile with the resolver's own rejection reason on the ones that do
   not qualify (same rule as the sheet), and "Ask at start" forgets the memory. Setting a
   profile from Settings writes exactly what a start would have remembered.
6. **New Workflow… reveals rather than opens.** The default app for `.yaml` is unpredictable
   (Xcode, TextEdit, an IDE); revealing the file beside the row that now shows its validation
   status is the safe default, and the row's Reveal does the same later.
7. **Grace values stay constants.** The plan says the watchdog grace periods are "global
   settings (Settings › Workflows)", but they are not in D1's slice contents and B2 grilled
   their defaults; a Watchdog section is a small follow-up once a user needs to move them.
8. **No CLI or contract changes.** `prowl workflow list` already reports `enabled` and
   validation; the page is a GUI over the same data.

## Implementation shape

- `supacode/CLIService/CLIServiceStatus.swift` (+ publisher, client), `CLISocketServer`
  status transitions, `SettingsFeature.cliServiceStatus` + `refreshCLIServiceStatus`,
  Connection status row in `CommandLineToolSettingsView`.
- `supacode/Features/Settings/Reducer/WorkflowsSettingsFeature.swift`,
  `Views/WorkflowsSettingsView.swift`, `SettingsSection.workflows`, sidebar row.
- `supacode/Domain/Workflow/WorkflowSettingsCatalog.swift` (pure rows),
  `WorkflowStarterTemplate.swift` (template + unique file name),
  `supacode/Clients/Workflow/WorkflowSettingsClient.swift` (scan / create / reveal / watch),
  `supacode/Features/Help/WorkflowAuthoringPrompt.swift` (localized prompt),
  `AskAgentHelpView` gains an init over explicit strings.
- `WorkflowStartContext.cliServiceFailure` and the sheet banner variant.
- Docs: `docs/components/workflows.md` (new), `README.md`, `settings.md`,
  `reference/settings-fields.md`, `cli.md`, `command-palette.md`, `active-agents.md`,
  `agent-profiles.md`; the `prowl-workflow` skill mentions the page.

## Review

Adversarial review by the neighbouring Pi reviewer (`prowl agents dispatch` into its pane,
briefs and findings under `/tmp/prowl-d1-review/`), read-only, no builds in the shared
checkout.

- **Round 1 — 2 P1 + 2 P2, all acted on.** P1: the directory vnode watcher missed in-place
  saves (an editor writing a file touches the file's vnode, not the directory's) — every
  discovered file is now watched too, re-armed on each reload, pinned by a real-vnode test.
  P1: a dangling `prowl` link (`.broken`) counted as installed for the Settings banner and the
  start-sheet gate — `CLIInstallStatus.isUsable` (installed or another live build; never
  broken or missing) now drives both, and the banner offers Repair. P2: a `stopped` socket
  status carried no reason, so the start gate treated it as reachable —
  `CLIServiceStatus.unreachableDescription` (nil only while listening) is the gate for the
  sheet and the page; `failureDescription` stays the Connection row's failure text. P2: the
  start composition read the status publisher directly — it now reads the dependency client,
  the same source Settings uses (a composition-level test was not added: the assembly needs
  the app store and terminal manager; the gate itself is covered from the context down).

## Verification plan

Red-first unit tests: `CLIServiceStatus` descriptions and server transitions (already-owned
path → `failed(.socketAlreadyOwned)`), Settings reducer reads a stubbed status, the starter
template validates with zero errors and unique names increment, catalog rows (enabled/
shadowed/bind label/binding candidates), reducer persistence of toggle / bind mode / binding
memory, watcher debounce on `TestClock`, start-context/sheet gating on a socket failure.
Then `make check`, `make test`, `make build-app`; adversarial review rounds; an isolated
Debug E2E over the page (toggle → palette visibility, bind override → sheet behavior, New
Workflow… → row → edit → live status, Reveal, Ask an Agent…, CLI banner with the CLI
uninstalled, Connection status with a second instance holding the socket).
