// supacode/Features/Workflow/Models/WorkflowStartContext.swift
// The start sheet's raw material (docs-ai 063 C2): what the GUI needs to show the sheet or
// decide a run can start immediately, assembled by the live WorkflowStartClient from the same
// catalog, resolver, and settings the CLI path reads. Submission still goes through admission;
// nothing here re-derives eligibility beyond presenting the resolver's own answer.

import Foundation
import ProwlCLIShared

/// One workflow as an entry point lists it (palette, capsule popover, Active Agents menu).
nonisolated struct WorkflowStartCatalogItem: Equatable, Sendable, Identifiable {
  /// The scope-qualified preference key used by `disabledWorkflowIDs` and bind-mode overrides.
  let key: String
  let scope: WorkflowScope
  let fileURL: URL
  let workflowID: String
  let name: String
  let workflowDescription: String?
  let icon: String?
  /// Set for a file that failed validation: listed only in the capsule popover, dimmed with this.
  let validationFailure: String?

  var id: String { key }
  var isRunnable: Bool { validationFailure == nil }

  /// Shared pure projection for the palette, Agents capsule, and start context. Keeping the
  /// YAML icon and source identity here prevents entry points from re-reading or partially
  /// reconstructing a definition.
  static func make(
    entry: WorkflowCatalogEntry,
    disabledWorkflowIDs: Set<String>,
    repositoryRootPath: String?
  ) -> Self? {
    guard !entry.shadowed else { return nil }
    let file = entry.file
    guard let workflowID = file.id else {
      let filename = file.url.lastPathComponent
      return Self(
        key: "\(file.scope.rawValue)/file:\(filename)",
        scope: file.scope,
        fileURL: file.url,
        workflowID: filename,
        name: filename,
        workflowDescription: nil,
        icon: nil,
        validationFailure: "Cannot parse the file.")
    }
    guard
      let key = WorkflowPreferenceKey.make(
        scope: file.scope,
        workflowID: workflowID,
        repositoryRootPath: repositoryRootPath),
      !disabledWorkflowIDs.contains(key)
    else { return nil }
    let errors = file.diagnostics.errorCount
    return Self(
      key: key,
      scope: file.scope,
      fileURL: file.url,
      workflowID: workflowID,
      name: file.definition?.name ?? workflowID,
      workflowDescription: file.definition?.description,
      icon: file.definition?.icon,
      validationFailure: file.isValid ? nil : "\(errors) validation error\(errors == 1 ? "" : "s")")
  }
}

/// A pane offered as the `current` source or a `pick` binding. `agentToken == nil` is a bare
/// shell — offered only as a source, and only valid while no delivery to `current` survives.
nonisolated struct WorkflowStartPaneCandidate: Equatable, Sendable, Identifiable {
  let surfaceID: UUID
  /// The short CLI handle ("p7") when known; stable for the app's lifetime.
  let handle: String?
  let agentToken: String?
  let agentDisplayName: String?
  let paneTitle: String

  var id: UUID { surfaceID }
}

/// A `launch` role as the sheet presents it: the resolver's answer plus picker material.
nonisolated struct WorkflowStartLaunchRole: Equatable, Sendable, Identifiable {
  struct Candidate: Equatable, Sendable, Identifiable {
    let profileID: UUID
    let name: String
    let agentToken: String
    /// nil = selectable; otherwise why the profile cannot serve this role (dimmed row).
    let unavailableReason: String?

    var id: UUID { profileID }
  }

  let name: String
  /// The YAML `bind` with the per-workflow override applied.
  let effectiveBind: WorkflowBindMode
  /// The resolver's pre-selection (any tier); nil when it ended at `ask`.
  let resolvedProfileID: UUID?
  let candidates: [Candidate]
  let suggestion: WorkflowProfileSuggestion?
  /// A remembered binding or override that failed re-validation, for the picker footnote.
  let rejectedNote: String?

  var id: String { name }
}

nonisolated struct WorkflowStartPickRole: Equatable, Sendable, Identifiable {
  let name: String
  let candidates: [WorkflowStartPaneCandidate]

  var id: String { name }
}

/// The `current` role's source picker material (the GUI equivalent of the CLI `[source]`).
nonisolated struct WorkflowStartSource: Equatable, Sendable {
  let roleName: String
  let candidates: [WorkflowStartPaneCandidate]
  let preselectedSurfaceID: UUID?
  /// An Active Agents row pins its own pane as the source (011 decision 2 "fixed there");
  /// the picker renders read-only and re-selection is refused.
  var isPreselectionFixed = false
}

nonisolated struct WorkflowStartContext: Equatable, Sendable {
  let item: WorkflowStartCatalogItem
  let definition: WorkflowDefinition
  let worktreeID: String
  let worktreeName: String
  /// nil when the workflow declares no `current` role (it runs against the worktree).
  let source: WorkflowStartSource?
  let launchRoles: [WorkflowStartLaunchRole]
  let pickRoles: [WorkflowStartPickRole]
  let cliInstalled: Bool
  /// The user's per-workflow tri-state override, already folded into each role's
  /// `effectiveBind`; carried so the sheet can show the "Don't ask again" toggle state.
  let bindModeOverride: WorkflowBindModeOverride.Mode?
  /// Why `prowl` cannot reach this app (docs-ai 063 D1 preflight): nil only while Prowl listens;
  /// a stopped server carries a reason too. Participants deliver through the CLI, so a run
  /// cannot start until this clears.
  var cliServiceFailure: String?
  /// What occupies the install path when `cliInstalled` is false, for the banner's action
  /// (Install / Repair / Reinstall); nil reads as a plain Install.
  var cliInstallStatus: CLIInstallStatus?
  var requiresBundleApproval = false

  /// nil = nothing the sheet can do (a real file or directory occupies the slot).
  var cliInstallActionTitle: String? {
    (cliInstallStatus ?? .notInstalled).installActionTitle
  }

  var cliInstallBlockerCopy: String {
    (cliInstallStatus ?? .notInstalled).workflowBlockerCopy
  }

  /// Steps offering a "Skip" choice at start: every step with an `expect` (§9 `--skip`).
  var skipOptions: [(stepID: String, title: String?)] {
    definition.flattenedSteps.compactMap { step in
      step.action.expect == nil ? nil : (step.id, step.title)
    }
  }

  /// dsl-spec §3 `bind: auto`: the sheet appears only when something is genuinely undecided.
  /// Nothing is undecided when every launch role is effectively `auto` and resolved, there is
  /// no `pick` role (those are always an explicit choice), every input has a default, and the
  /// preselected source satisfies the delivery requirement with nothing skipped.
  var canStartImmediately: Bool {
    guard !requiresBundleApproval, item.isRunnable, cliInstalled, cliServiceFailure == nil, pickRoles.isEmpty else {
      return false
    }
    guard launchRoles.allSatisfy({ $0.effectiveBind == .auto && $0.resolvedProfileID != nil })
    else { return false }
    guard definition.inputs.allSatisfy({ $0.defaultValue != nil }) else { return false }
    guard let source else { return true }
    guard
      let preselected = source.candidates.first(where: {
        $0.surfaceID == source.preselectedSurfaceID
      })
    else { return false }
    let needsAgent = WorkflowRunAdmission.deliversToCurrentRole(definition, skipped: [])
    return !needsAgent || preselected.agentToken != nil
  }
}

/// What the sheet (or the immediate-start path) submits — the same vocabulary `workflow run`
/// accepts, so admission stays the single authority. Persisting "Don't ask again" is the
/// reducer's business, not the run's.
nonisolated struct WorkflowStartRequest: Equatable, Sendable {
  let workflowID: String
  let worktreeID: String
  /// The chosen `current` source pane; nil runs against the worktree.
  let sourceSurfaceID: UUID?
  /// `<role>=<binding>` strings in the CLI's own grammar (dsl-spec §9).
  let roleBindings: [String]
  /// `<name>=<value>` strings for inputs the user edited (defaults are left to admission).
  let inputValues: [String]
  let skippedSteps: [String]
}

nonisolated enum WorkflowStartOutcome: Equatable, Sendable {
  case started
  case failed(code: String, message: String)
}
