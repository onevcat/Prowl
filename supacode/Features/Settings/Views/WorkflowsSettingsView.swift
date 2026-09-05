import ComposableArchitecture
import SwiftUI

/// Settings → Agents → Workflows. The root is intentionally a compact index; every control
/// whose effect is scoped to one workflow lives on the pushed detail page.
struct WorkflowsSettingsView: View {
  @Bindable var store: StoreOf<WorkflowsSettingsFeature>

  var body: some View {
    NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
      Form {
        WorkflowSettingsSections(store: store, showsIntroduction: true)
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
    } destination: { detailStore in
      WorkflowSettingsDetailView(store: detailStore)
    }
    .onDisappear { store.send(.teardown) }
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
      .help("Create a starter YAML file and open it in your default editor")

      Button("Ask an Agent…") {
        store.send(.askAgentTapped)
      }
      .help("Copy a prompt that asks your coding agent to write a workflow")

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

func workflowAuthoringPromptStrings(directory: URL) -> AskAgentHelpStrings {
  let resources = SupacodePaths.bundledDocsURL?.deletingLastPathComponent()
  let skill =
    resources?.appending(path: "skills/prowl-workflow/SKILL.md", directoryHint: .notDirectory)
    .path(percentEncoded: false)
    ?? "/Applications/Prowl.app/Contents/Resources/skills/prowl-workflow/SKILL.md"
  let manual =
    SupacodePaths.bundledDocsURL?.appending(
      path: "components/workflows.md", directoryHint: .notDirectory
    )
    .path(percentEncoded: false)
    ?? "/Applications/Prowl.app/Contents/Resources/docs/components/workflows.md"
  return WorkflowAuthoringPrompt.strings(
    skillPath: skill,
    manualPath: manual,
    workflowsDirectory: directory.path(percentEncoded: false))
}
