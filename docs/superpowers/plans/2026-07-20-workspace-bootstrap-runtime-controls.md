# Workspace Bootstrap Runtime Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make existing workspace bootstrap bindings read-only after materialization while exposing each child repository's latest run result, log, and per-profile manual Run action.

**Architecture:** `.prowl/workspace.json` remains the immutable source of post-creation profile bindings and automatic policy. `ProjectWorkspaceBootstrapExecutor` remains the runtime writer; a focused snapshot loader reads its existing `bootstrap-state.json` and validates log paths for `RepositorySettingsFeature`. Existing child cards render runtime controls, while new-child materialization keeps the binding editor.

**Tech Stack:** Swift 6.2, SwiftUI, Composable Architecture, swift-dependencies, Swift Testing, Foundation file APIs.

## Global Constraints

- Target macOS 26.0+ and Swift 6.2+.
- Use `@ObservableState` for reducer state and reducer actions for all view mutations.
- Use `SupaLogger`; do not add `print()` or direct `os.Logger` calls.
- Preserve existing `.prowl/workspace.json` bootstrap metadata during unrelated workspace settings saves.
- Existing child bindings are read-only; only workspace creation and new-child materialization may select or order profiles.
- Manual Run must not patch workspace metadata.
- Linked child repositories remain non-runnable.
- Update `docs/components/workspaces.md` with the user-facing behavior.
- Stage and commit only changes made by this implementation; preserve pre-existing working-tree edits.

---

### Task 1: Load Bootstrap Runtime State

**Files:**
- Modify: `supacode/Clients/Workspace/ProjectWorkspaceBootstrapExecutor.swift`
- Test: `supacodeTests/ProjectWorkspaceBootstrapExecutorTests.swift`

**Interfaces:**
- Produces: `ProjectWorkspaceBootstrapRuntimeSnapshot.empty`
- Produces: `ProjectWorkspaceBootstrapRuntimeSnapshot.load(workspaceRootURL:fileClient:) throws`
- Produces: `ProjectWorkspaceBootstrapRuntimeSnapshot.state`
- Produces: `ProjectWorkspaceBootstrapRuntimeSnapshot.logURLsByRepositoryID`
- Consumes: existing `ProjectWorkspaceBootstrapState`, `ProjectWorkspaceBootstrapRepositoryState`, and `.prowl/bootstrap-state.json` format.

- [ ] **Step 1: Write failing snapshot-loader tests**

Add tests that write an ISO-8601 `bootstrap-state.json` and one referenced log, then assert:

```swift
let snapshot = try ProjectWorkspaceBootstrapRuntimeSnapshot.load(workspaceRootURL: rootURL)
#expect(snapshot.state.repositories["app"]?.lastStatus == .succeeded)
#expect(snapshot.logURLsByRepositoryID["app"] == logURL)
```

Add a stale-log case that keeps the saved run state but omits the URL:

```swift
let snapshot = try ProjectWorkspaceBootstrapRuntimeSnapshot.load(workspaceRootURL: rootURL)
#expect(snapshot.state.repositories["app"] != nil)
#expect(snapshot.logURLsByRepositoryID["app"] == nil)
```

- [ ] **Step 2: Run the tests and verify they fail**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:"supacodeTests/ProjectWorkspaceBootstrapExecutorTests" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: compilation fails because `ProjectWorkspaceBootstrapRuntimeSnapshot` does not exist.

- [ ] **Step 3: Implement the runtime snapshot loader**

Add file existence support to the existing file client and introduce this focused value type:

```swift
nonisolated struct ProjectWorkspaceBootstrapRuntimeSnapshot: Equatable, Sendable {
  var state: ProjectWorkspaceBootstrapState
  var logURLsByRepositoryID: [String: URL]

  static let empty = Self(
    state: ProjectWorkspaceBootstrapState(repositories: [:]),
    logURLsByRepositoryID: [:]
  )

  static func load(
    workspaceRootURL: URL,
    fileClient: ProjectWorkspaceBootstrapFileClient = .live
  ) throws -> Self {
    let stateURL = workspaceRootURL
      .appending(path: ProjectWorkspace.metadataDirectoryName, directoryHint: .isDirectory)
      .appending(path: "bootstrap-state.json", directoryHint: .notDirectory)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let state = try decoder.decode(
      ProjectWorkspaceBootstrapState.self,
      from: fileClient.readData(stateURL)
    )
    var logURLs: [String: URL] = [:]
    for (repositoryID, repositoryState) in state.repositories {
      let path = repositoryState.lastLogPath
      let url = path.hasPrefix("/")
        ? URL(fileURLWithPath: path)
        : workspaceRootURL.appending(path: path, directoryHint: .notDirectory)
      if fileClient.fileExists(url) {
        logURLs[repositoryID] = url
      }
    }
    return Self(state: state, logURLsByRepositoryID: logURLs)
  }
}
```

Use the same state URL helper from executor writes so reader and writer cannot drift.

- [ ] **Step 4: Run the loader tests**

Run the Task 1 test command again.

Expected: all `ProjectWorkspaceBootstrapExecutorTests` pass.

- [ ] **Step 5: Commit the runtime loader**

Stage only the two Task 1 files and commit:

```bash
git commit -m "feat: Load workspace bootstrap runtime state"
```

---

### Task 2: Make Repository Settings Runtime-Only

**Files:**
- Modify: `supacode/Features/RepositorySettings/Reducer/RepositorySettingsFeature.swift`
- Test: `supacodeTests/RepositorySettingsFeatureTests.swift`

**Interfaces:**
- Consumes: `ProjectWorkspaceBootstrapRuntimeSnapshot.load(workspaceRootURL:)` from Task 1.
- Consumes: existing `OpenURLClient.open(_:)` dependency.
- Produces: `State.workspaceBootstrapRuntime`.
- Produces actions: `loadWorkspaceBootstrapRuntime`, `workspaceBootstrapRuntimeLoaded`, and `openWorkspaceBootstrapLogButtonTapped(id:)`.

- [ ] **Step 1: Add failing reducer tests**

Cover these behaviors with concrete workspace fixtures:

```swift
await store.send(.loadWorkspaceBootstrapRuntime)
await store.receive(\.workspaceBootstrapRuntimeLoaded) {
  $0.workspaceBootstrapRuntime = expectedSnapshot
}
```

```swift
await store.send(.openWorkspaceBootstrapLogButtonTapped(id: "app"))
#expect(openedURLs.value == [expectedLogURL])
```

Verify that running `sync-app`:

- runs in `<workspace>/app`;
- reloads runtime state after success and failure;
- leaves `state.workspace` and the bytes of `.prowl/workspace.json` unchanged;
- does nothing when the manifest does not bind that profile;
- does nothing when the local Script Profile is missing.

Add a metadata-save regression test asserting existing `run_on: [create, manual]` and
`required: true` survive edits to description or guide metadata.

- [ ] **Step 2: Run reducer tests and verify failures**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:"supacodeTests/RepositorySettingsFeatureTests" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: new actions/state do not compile or expectations fail against the mutable binding behavior.

- [ ] **Step 3: Add runtime state and loading actions**

Add:

```swift
var workspaceBootstrapRuntime = ProjectWorkspaceBootstrapRuntimeSnapshot.empty
```

Load it from `.task` for workspaces and after each manual run. Missing or malformed state logs a warning and sends `.empty`; it must not set `workspaceSaveError`.

Inject `OpenURLClient` and open only URLs present in `logURLsByRepositoryID`.

- [ ] **Step 4: Remove post-creation binding mutation**

Delete existing-child reducer actions and handlers for profile add/remove/move and timing edits. Preserve bootstrap metadata when deriving an updated workspace:

```swift
var updated = entry
updated.role = Self.trimmedNonEmpty(repositoryDraft.role)
updated.agentNotes = Self.trimmedNonEmpty(repositoryDraft.agentNotes)
// Keep updated.bootstrap from the saved entry.
```

For a newly added child, continue creating the bootstrap value from its creation draft so
selection, ordering, `on_add`, and Required remain materialization-time choices.

- [ ] **Step 5: Make per-profile Run transient and defensive**

Resolve the repository and profile from saved sources rather than `updatedWorkspaceFromDraft()`:

```swift
guard let entry = state.workspace?.repositories.first(where: { $0.id == id }),
  entry.bootstrap?.scriptIDs.contains(scriptID) == true,
  scriptProfiles.contains(where: { $0.id == scriptID })
else { return .none }
```

Copy the entry into a local value and replace only the transient request's bootstrap with
`scriptIDs: [scriptID]`, `runOn: [.manual]`, and `required: true`. Do not save this copy.

- [ ] **Step 6: Run reducer tests**

Run the Task 2 test command again.

Expected: all `RepositorySettingsFeatureTests` pass, including metadata preservation and runtime refresh.

- [ ] **Step 7: Commit reducer behavior**

Stage only Task 2 changes and commit:

```bash
git commit -m "refactor: Make workspace bootstrap runtime-only"
```

---

### Task 3: Replace Existing-Child Binding UI with Runtime Controls

**Files:**
- Modify: `supacode/Features/Settings/Views/RepositorySettingsView.swift`
- Test: `supacodeTests/RepositorySettingsFeatureTests.swift`

**Interfaces:**
- Consumes: `State.workspaceBootstrapRuntime` and runtime actions from Task 2.
- Preserves: profile binding editor for `RepositoryDraft.isNew == true`.

- [ ] **Step 1: Add state-level presentation assertions**

Add focused assertions for the data consumed by the view:

```swift
#expect(store.state.workspaceDraft?.repositories[id: "app"]?.bootstrapScriptIDs == ["sync-app"])
#expect(store.state.workspaceBootstrapRuntime.state.repositories["app"]?.lastStatus == .failed)
#expect(store.state.workspaceBootstrapRuntime.logURLsByRepositoryID["app"] == expectedLogURL)
```

Also cover a child with no binding, a missing local profile, and a linked child.

- [ ] **Step 2: Split configuration and runtime views**

Keep the current Add/reorder/remove controls in a renamed
`workspaceBootstrapConfigurationEditor(_:)` used only for new repository drafts.

Add `workspaceBootstrapRuntimeView(_:)` for saved entries:

```swift
if repository.isNew {
  workspaceBootstrapConfigurationEditor(repository)
} else if !repository.bootstrapScriptIDs.isEmpty {
  workspaceBootstrapRuntimeView(repository)
}
```

The runtime view shows:

- `Never run`, or the latest `Succeeded` / `Failed` result and completion time;
- `View Log` only when the reducer loaded a valid log URL;
- manifest-ordered, read-only profile rows;
- `Run` per available profile;
- `Missing Profile` and a disabled Run action when the local definition is absent;
- disabled Run for linked children and for the active repository/profile run ID.

Do not add Add Script, remove, or move controls to saved repository rows.

- [ ] **Step 3: Run focused tests and build**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:"supacodeTests/RepositorySettingsFeatureTests" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
make build-app
```

Expected: tests pass and build reports zero errors.

- [ ] **Step 4: Commit the runtime UI**

Stage only Task 3 changes and commit:

```bash
git commit -m "feat: Show workspace bootstrap run status"
```

---

### Task 4: Documentation and Final Verification

**Files:**
- Modify: `docs/components/workspaces.md`
- Modify: `docs-ai/042-project-workspaces/003-bootstrap-runtime-controls.md`

**Interfaces:**
- Documents the implementation produced by Tasks 1-3.

- [ ] **Step 1: Update user-facing workspace documentation**

Replace the statement that existing workspace settings can choose scripts. Document that:

- binding and automatic policy are selected while materializing a workspace or new child;
- existing child cards are read-only runtime surfaces;
- each bound profile can be run manually;
- latest status and log are local runtime state under `.prowl/`;
- missing local profiles disable Run without deleting the manifest reference.

- [ ] **Step 2: Complete the docs-ai amendment**

Replace the planned Ref with the implementation commit(s), list the resulting files, and
record any deviation from the approved design.

- [ ] **Step 3: Run final verification**

Run:

```bash
make check
make build-app
git diff --check
```

Also rerun the two focused suites from Tasks 1 and 2. Expected: all targeted tests and the app build pass. Report unrelated lint or shared-state failures separately with exact output.

- [ ] **Step 4: Commit documentation**

Stage only the two Task 4 documentation files and commit:

```bash
git commit -m "docs: Document workspace bootstrap runtime controls"
```

- [ ] **Step 5: Inspect final repository state**

Run:

```bash
git status --short --branch
git log -5 --oneline
```

Expected: implementation commits are present; all pre-existing user changes remain unstaged and uncommitted.
