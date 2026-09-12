import ComposableArchitecture
import SwiftUI

/// Settings → Agents → Workflows. The root is intentionally a compact index; every control
/// whose effect is scoped to one workflow lives on the pushed detail page.
struct WorkflowsSettingsView: View {
  @State private var historyStore = Store(initialState: WorkflowHistoryFeature.State()) { WorkflowHistoryFeature() }
  @Bindable var store: StoreOf<WorkflowsSettingsFeature>

  var body: some View {
    NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
      Form {
        WorkflowSettingsSections(store: store, showsIntroduction: true)
        WorkflowHistorySummarySection(store: historyStore)
      }
      .formStyle(.grouped)
      .navigationTitle("Workflows")
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .task { store.send(.task) }
      .alert($store.scope(state: \.alert, action: \.alert))
      .sheet(isPresented: $store.isAuthoringPromptPresented.sending(\.setAuthoringPromptPresented)) {
        AskAgentHelpView(
          strings: workflowAuthoringPromptStrings(directory: store.workflowDirectory)
        ) {
          store.send(.setAuthoringPromptPresented(false))
        }
      }
      .sheet(
        isPresented: Binding(get: { store.newWorkflow != nil }, set: { if !$0 { store.send(.dismissNewWorkflow) } })
      ) {
        NewWorkflowSheet(store: store)
      }
    } destination: { detailStore in
      WorkflowSettingsDetailView(store: detailStore)
    }
    .onDisappear { store.send(.teardown) }
  }
}

/// Settings › Workflows › Run History: what the archive holds and a way to clear it. Inspecting
/// individual runs is the toolbar's Workflow History popover; retention is automatic.
private struct WorkflowHistorySummarySection: View {
  @Bindable var store: StoreOf<WorkflowHistoryFeature>

  var body: some View {
    Section {
      HStack(alignment: .firstTextBaseline) {
        Text(summary)
        Spacer()
        if store.isBusy {
          ProgressView().controlSize(.small)
        }
        Button("Clear History…", role: .destructive) { store.send(.clearTapped) }
          .disabled(store.isBusy || store.removableCount == 0)
          .help("Delete every finished run from Workflow History")
      }
      if let error = store.error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .font(.callout)
          .textSelection(.enabled)
      } else if let result = store.result {
        Text(result)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Run History")
    } footer: {
      Text(
        "Runs are listed in the toolbar's Workflow History. Records are stored in your home directory, "
          + "outside project folders, and finished runs expire automatically.")
    }
    .task { store.send(.refresh) }
    .alert($store.scope(state: \.alert, action: \.alert))
  }

  private var summary: String {
    guard store.hasLoaded else { return "Loading run history…" }
    let count = store.runCount
    let size = ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file)
    if count == 0 { return "No workflow runs recorded." }
    return "\(count) run\(count == 1 ? "" : "s") · \(size) on disk"
  }
}

/// Shared compact index used by both Agents → Workflows and each Repository Settings page.
/// The surrounding Form/NavigationStack belongs to the host so repository workflows do not
/// need an intermediate destination.
struct WorkflowSettingsSections: View {
  @Bindable var store: StoreOf<WorkflowsSettingsFeature>
  let showsIntroduction: Bool

  var body: some View {
    if showsIntroduction {
      Section {
        Text(
          "Workflows coordinate agents for repeatable tasks. Select one to review its setup or run it."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }

    if let blocker = store.cliBlocker {
      cliSection(blocker)
    }

    if let loadError = store.loadError {
      Section {
        Label(loadError, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .font(.callout)
      }
    }

    switch store.settingsScope {
    case .global:
      if !store.catalog.bundle.isEmpty {
        workflowSection(title: "Built-in", rows: store.catalog.bundle, includesActions: false)
      }
      workflowSection(title: "Your Workflows", rows: store.catalog.user, includesActions: true)

    case .repository:
      workflowSection(title: "Workflows", rows: store.displayedRows, includesActions: true)
    }
  }

  private func workflowSection(
    title: String,
    rows: [WorkflowSettingsRow],
    includesActions: Bool
  ) -> some View {
    Section(title) {
      if rows.isEmpty {
        Text(emptyMessage)
          .foregroundStyle(.secondary)
          .font(.callout)
      }
      ForEach(rows) { row in
        NavigationLink(
          state: WorkflowSettingsDetailFeature.State(row: row, runTargets: store.runTargets)
        ) {
          WorkflowCompactRow(row: row)
        }
      }
      if includesActions {
        actionRow
      }
    }
  }

  private var emptyMessage: String {
    switch store.settingsScope {
    case .global:
      "No personal workflows yet. Create one or ask an agent to write it."
    case .repository:
      "No workflows for this repository."
    }
  }

  private var actionRow: some View {
    HStack(spacing: 8) {
      Button {
        store.send(.newWorkflowTapped)
      } label: {
        Label("New Workflow…", systemImage: "plus")
      }
      .help("Name a workflow, pick a starter, and open it in your default editor")

      Button("Create with Agent…") {
        store.send(.askAgentTapped)
      }
      .help("Copy a prompt that asks your coding agent to write a workflow for you")

      Spacer()

      Button {
        store.send(.revealUserFolderTapped)
      } label: {
        Image(systemName: "folder")
      }
      .buttonStyle(.borderless)
      .help("Show \(abbreviated(store.workflowDirectory)) in Finder")
      .accessibilityLabel("Show Workflows Folder")
    }
  }

  private func cliSection(_ blocker: WorkflowsSettingsFeature.CLIBlocker) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          switch blocker {
          case .cliUnusable(let status):
            Label(
              "Workflows need the prowl command line tool.",
              systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            Spacer()
            if let title = status.installActionTitle {
              Button(title) { store.send(.installCLITapped) }
                .help("\(title) the prowl command line tool at /usr/local/bin/prowl")
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
          case .socketUnavailable:
            Label(
              "Prowl is not listening for the prowl command.",
              systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
          }
        }
        switch blocker {
        case .cliUnusable(let status):
          Text(status.workflowBlockerCopy)
            .foregroundStyle(.secondary)
        case .socketUnavailable(let reason):
          Text(reason)
            .foregroundStyle(.secondary)
        }
      }
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func abbreviated(_ url: URL) -> String {
    (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }
}

struct WorkflowCompactRow: View {
  let row: WorkflowSettingsRow

  var body: some View {
    HStack(spacing: 10) {
      WorkflowIconImage(icon: row.icon, pointSize: 18)
        .frame(width: 22, height: 22)

      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(row.name)
            .foregroundStyle(.primary)
          if let workflowID = row.workflowID, workflowID != row.name {
            Text(workflowID)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }
        if let description = row.description, !description.isEmpty {
          Text(description)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      Spacer(minLength: 12)
      WorkflowStatusLabel(status: row.status)
    }
    .padding(.vertical, 2)
    .contentShape(.rect)
  }
}

struct WorkflowIconImage: View {
  let icon: String?
  let pointSize: CGFloat

  var body: some View {
    Image(systemName: icon ?? "point.3.connected.trianglepath.dotted")
      .font(.system(size: pointSize))
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
  }
}

struct WorkflowStatusLabel: View {
  let status: WorkflowSettingsRow.Status

  var body: some View {
    Label(title, systemImage: symbol)
      .font(.caption)
      .foregroundStyle(color)
      .lineLimit(1)
      .help(helpText)
  }

  private var title: String {
    switch status {
    case .invalid(let errors): "Invalid · \(errors) error\(errors == 1 ? "" : "s")"
    case .disabled: "Disabled"
    case .superseded: "Superseded"
    case .readyWithWarnings(let warnings): "Ready · \(warnings) warning\(warnings == 1 ? "" : "s")"
    case .ready: "Ready"
    }
  }

  private var symbol: String {
    switch status {
    case .invalid: "xmark.octagon.fill"
    case .disabled: "pause.circle.fill"
    case .superseded: "arrow.trianglehead.branch"
    case .readyWithWarnings: "exclamationmark.triangle.fill"
    case .ready: "checkmark.circle.fill"
    }
  }

  private var color: Color {
    switch status {
    case .invalid: .red
    case .disabled, .superseded: .secondary
    case .readyWithWarnings: .orange
    case .ready: .green
    }
  }

  private var helpText: String {
    switch status {
    case .invalid(let errors):
      "This workflow has \(errors) validation error\(errors == 1 ? "" : "s")."
    case .disabled:
      "This workflow is hidden from launch surfaces and cannot run."
    case .superseded:
      "Another file with the same workflow ID takes precedence."
    case .readyWithWarnings(let warnings):
      "Ready with \(warnings) warning\(warnings == 1 ? "" : "s")."
    case .ready:
      "Ready to run."
    }
  }
}

func workflowAuthoringPromptStrings(
  directory: URL, draft: WorkflowStarterTemplate.Request? = nil
) -> AskAgentHelpStrings {
  let documentation = WorkflowStarterTemplate.bundledDocumentation
  var draft = draft
  draft?.documentation = documentation
  return WorkflowAuthoringPrompt.strings(
    skillPath: documentation.skillPath,
    manualPath: documentation.manualPath,
    workflowsDirectory: directory.path(percentEncoded: false), draft: draft)
}

extension WorkflowStarterTemplate {
  /// The manual and skill inside this app bundle, falling back to the standard install path.
  nonisolated static var bundledDocumentation: Documentation {
    let resources = SupacodePaths.bundledDocsURL?.deletingLastPathComponent()
    return Documentation(
      manualPath: SupacodePaths.bundledDocsURL?
        .appending(path: "components/workflows.md", directoryHint: .notDirectory)
        .path(percentEncoded: false) ?? Documentation.standard.manualPath,
      skillPath: resources?
        .appending(path: "skills/prowl-workflow/SKILL.md", directoryHint: .notDirectory)
        .path(percentEncoded: false) ?? Documentation.standard.skillPath)
  }
}
