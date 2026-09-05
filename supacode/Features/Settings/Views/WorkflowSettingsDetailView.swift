import ComposableArchitecture
import SwiftUI

struct WorkflowSettingsDetailView: View {
  @Bindable var store: StoreOf<WorkflowSettingsDetailFeature>

  var body: some View {
    Group {
      if let row = store.row {
        Form {
          workflowSection(row)
          runSection(row)
          rolesSection(row)
          runSetupSection(row)
          validationSection(row)
          sourceFileSection(row)
        }
        .formStyle(.grouped)
        .navigationTitle(row.name)
      } else {
        ContentUnavailableView {
          Label("Workflow Unavailable", systemImage: "doc.badge.ellipsis")
        } description: {
          Text("The workflow file was moved or deleted. Go back to choose another workflow.")
        }
        .navigationTitle("Workflow Unavailable")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .alert($store.scope(state: \.alert, action: \.alert))
  }

  private func workflowSection(_ row: WorkflowSettingsRow) -> some View {
    Section("Workflow") {
      HStack(alignment: .top, spacing: 12) {
        WorkflowIconImage(icon: row.icon, pointSize: 24)
          .frame(width: 30, height: 30)
        VStack(alignment: .leading, spacing: 4) {
          Text(row.name)
            .font(.headline)
          if let description = row.description, !description.isEmpty {
            Text(description)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 16)
        WorkflowStatusLabel(status: row.status)
      }

      if let workflowID = row.workflowID {
        LabeledContent("ID") {
          Text(workflowID)
            .font(.body.monospaced())
            .textSelection(.enabled)
        }
      }

      if row.settingsKey != nil {
        Toggle(
          "Enabled",
          isOn: Binding(
            get: { row.isEnabled },
            set: { store.send(.enabledChanged($0)) })
        )
        .help(
          row.isEnabled
            ? "Available from workflow launch surfaces and the prowl CLI"
            : "Hidden from workflow launch surfaces and rejected by the prowl CLI")
      }
    }
  }

  @ViewBuilder
  private func runSection(_ row: WorkflowSettingsRow) -> some View {
    Section("Run") {
      if let target = store.preferredRunTarget {
        HStack(spacing: 6) {
          Button {
            store.send(.runTapped(worktreeID: target.id, forceSheet: false))
          } label: {
            Label("Run in \(target.name)", systemImage: "play.fill")
          }
          .buttonStyle(.borderedProminent)
          .disabled(!canRun(row))
          .help(runHelp(row, target: target))

          Menu {
            Section("Run In") {
              ForEach(store.runTargets) { candidate in
                Button(candidate.displayName) {
                  store.send(.runTapped(worktreeID: candidate.id, forceSheet: false))
                }
              }
            }
            Divider()
            Button("Run with Options…") {
              store.send(.runTapped(worktreeID: target.id, forceSheet: true))
            }
          } label: {
            Image(systemName: "chevron.down")
              .accessibilityHidden(true)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .disabled(!canRun(row))
          .help("Choose another worktree or review options before running")
        }
      } else {
        Label("Open a worktree to run this workflow.", systemImage: "rectangle.stack.badge.plus")
          .foregroundStyle(.secondary)
      }

      if !canRun(row), let reason = unavailableRunReason(row) {
        Text(reason)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func rolesSection(_ row: WorkflowSettingsRow) -> some View {
    Section("Roles") {
      ForEach(row.roles) { role in
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            Text(role.name)
              .font(.body.monospaced())
            Spacer()
            Text(sourceLabel(role.source))
              .font(.callout)
              .foregroundStyle(.secondary)
              .help(sourceHelp(role.source))
          }
          Text(role.behaviorDescription)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if let launch = role.launch {
            preferredProfileMenu(launch)
          }
        }
        .padding(.vertical, 2)
      }

      if !row.launchRoles.isEmpty {
        Button("Manage Agent Profiles…") {
          store.send(.manageProfilesTapped)
        }
        .help("Open Settings → Agents → Profiles")
      }
    }
  }

  private func preferredProfileMenu(_ role: WorkflowSettingsRow.LaunchRole) -> some View {
    LabeledContent("Preferred Agent Profile") {
      Menu {
        Button("Choose Automatically") {
          store.send(.preferredProfileChanged(role.memoryKey, nil))
        }
        Divider()
        ForEach(role.candidates) { candidate in
          Button {
            store.send(.preferredProfileChanged(role.memoryKey, candidate.profileID))
          } label: {
            HStack {
              Text(candidate.name)
              if candidate.profileID == role.rememberedProfileID {
                Image(systemName: "checkmark")
                  .accessibilityHidden(true)
              }
            }
          }
          .disabled(candidate.unavailableReason != nil)
          .help(candidate.unavailableReason ?? candidate.agentToken)
        }
        if let rememberedProfileID = role.rememberedProfileID,
          !role.candidates.contains(where: { $0.profileID == rememberedProfileID })
        {
          Divider()
          Text("Deleted Profile")
        }
      } label: {
        Text(preferredProfileName(role))
      }
      .help(
        "Preferred profile for this launch role. Choose Automatically lets Prowl resolve "
          + "a qualifying profile when the workflow starts."
      )
    }
  }

  private func runSetupSection(_ row: WorkflowSettingsRow) -> some View {
    Section {
      Picker(
        "Run Setup",
        selection: Binding(
          get: { row.bindModeOverride },
          set: { store.send(.runSetupChanged($0)) })
      ) {
        Text("Follow Workflow").tag(Optional<WorkflowBindModeOverride.Mode>.none)
        Text("Always Review Before Running").tag(Optional(WorkflowBindModeOverride.Mode.ask))
        Text("Run Directly When Possible").tag(Optional(WorkflowBindModeOverride.Mode.auto))
      }
      .help(
        "Controls whether Prowl presents the start sheet after resolving profiles, required role choices, "
          + "and validation results."
      )

      Text(runSetupDescription(row))
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } header: {
      Text("Run Setup")
    }
  }

  private func validationSection(_ row: WorkflowSettingsRow) -> some View {
    Section {
      if let shadowNote = row.shadowNote {
        Label(shadowNote, systemImage: "arrow.trianglehead.branch")
          .foregroundStyle(.secondary)
      }
      if let precedenceNote = row.precedenceNote {
        Label(precedenceNote, systemImage: "arrow.trianglehead.branch")
          .foregroundStyle(.secondary)
      }
      if row.diagnostics.isEmpty {
        Label("No validation issues", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      } else {
        ForEach(Array(row.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(
              systemName: diagnostic.severity == .error
                ? "xmark.octagon.fill"
                : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
            .accessibilityLabel(diagnostic.severity == .error ? "Error" : "Warning")

            VStack(alignment: .leading, spacing: 2) {
              Text(diagnostic.message)
                .fixedSize(horizontal: false, vertical: true)
              HStack(spacing: 8) {
                if let location = diagnostic.location {
                  Text("Line \(location.line), column \(location.column)")
                }
                Text(diagnostic.code)
              }
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
            }
          }
        }
      }
    } header: {
      Text("Validation")
    } footer: {
      Text("Prowl revalidates automatically when the workflow file changes.")
    }
  }

  private func sourceFileSection(_ row: WorkflowSettingsRow) -> some View {
    Section("Source File") {
      HStack(spacing: 8) {
        Button("Open Workflow") {
          store.send(.openWorkflowTapped)
        }
        .help("Open \(row.fileName) in the default app for YAML files")

        Button {
          store.send(.revealInFinderTapped)
        } label: {
          Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help("Show \(row.fileName) in Finder")
        .accessibilityLabel("Reveal Workflow in Finder")

        Spacer()

        if row.scope == .bundle {
          Text("Built-in · Read Only")
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
          Button("Delete Workflow…", role: .destructive) {
            store.send(.deleteTapped)
          }
          .help("Move \(row.fileName) to Trash after confirmation")
        }
      }

      Text(abbreviated(row.url))
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .lineLimit(2)
        .truncationMode(.middle)
    }
  }

  private func canRun(_ row: WorkflowSettingsRow) -> Bool {
    row.isValid && row.isEnabled && row.shadowNote == nil && store.preferredRunTarget != nil
  }

  private func unavailableRunReason(_ row: WorkflowSettingsRow) -> String? {
    if !row.isValid { return "Fix the validation errors before running." }
    if row.shadowNote != nil { return "Another file with this ID takes precedence." }
    if !row.isEnabled { return "Enable this workflow before running." }
    return nil
  }

  private func runHelp(_ row: WorkflowSettingsRow, target: WorkflowSettingsRunTarget) -> String {
    unavailableRunReason(row) ?? "Run this workflow in \(target.displayName)"
  }

  private func sourceLabel(_ source: WorkflowRoleSource) -> String {
    switch source {
    case .current: "Current Pane"
    case .pick: "Choose Existing"
    case .launch: "Launch New"
    }
  }

  private func sourceHelp(_ source: WorkflowRoleSource) -> String {
    switch source {
    case .current:
      "Uses the pane that starts the workflow and its detected agent."
    case .pick:
      "Selects an existing agent pane when the workflow starts."
    case .launch:
      "Creates a new agent pane using the role's requirements and preferred profile."
    }
  }

  private func preferredProfileName(_ role: WorkflowSettingsRow.LaunchRole) -> String {
    guard let id = role.rememberedProfileID else { return "Choose Automatically" }
    return role.candidates.first { $0.profileID == id }?.name ?? "Deleted Profile"
  }

  private func runSetupDescription(_ row: WorkflowSettingsRow) -> String {
    switch row.bindModeOverride {
    case nil:
      switch row.declaredBind {
      case .ask:
        return "Uses the workflow file's setting, which reviews choices before running."
      case .auto:
        return
          "Uses the workflow file's setting, which runs directly when all required choices can be resolved."
      case nil:
        return "Uses the behavior declared in the workflow file."
      }
    case .ask:
      return "Always opens the review sheet before this workflow runs."
    case .auto:
      return
        "Starts directly when every required choice is available; otherwise Prowl opens the review sheet."
    }
  }

  private func abbreviated(_ url: URL) -> String {
    (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }
}
