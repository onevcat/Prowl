import ComposableArchitecture
import SwiftUI

/// Settings → Agents → Workflows: the CLI dependency banner, then one list per source (bundled,
/// `~/.prowl/workflows`, each repository's `.prowl/workflows`) with a row per file. Enable,
/// bind-mode, and binding edits go through `WorkflowsSettingsFeature`; this view only presents.
struct WorkflowsSettingsView: View {
  @Bindable var store: StoreOf<WorkflowsSettingsFeature>

  var body: some View {
    Form {
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
      builtInSection
      userSection
      repositorySections
    }
    .formStyle(.grouped)
    .navigationTitle("Workflows")
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task { store.send(.task) }
    .onDisappear { store.send(.teardown) }
    .alert($store.scope(state: \.alert, action: \.alert))
    .sheet(isPresented: $store.isAuthoringPromptPresented.sending(\.setAuthoringPromptPresented)) {
      AskAgentHelpView(strings: authoringPromptStrings) {
        store.send(.setAuthoringPromptPresented(false))
      }
    }
  }

  // MARK: - Sections

  private func cliSection(_ blocker: WorkflowsSettingsFeature.CLIBlocker) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          switch blocker {
          case .notInstalled(let repair):
            Label("Workflows need the prowl command line tool.", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            Spacer()
            Button(repair ? "Repair" : "Install") {
              store.send(.installCLITapped)
            }
            .help(
              repair
                ? "Replace the broken prowl link with the version bundled in this app"
                : "Install the prowl command line tool to /usr/local/bin"
            )
            .buttonStyle(.bordered)
            .controlSize(.small)
          case .socketUnavailable:
            Label("Prowl is not listening for the prowl command.", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
        switch blocker {
        case .notInstalled(let repair):
          Text(
            repair
              ? "The prowl link at /usr/local/bin points at an app that is gone. Participants deliver their "
                + "results through prowl, so a run cannot start until it is repaired."
              : "Participants deliver their results through prowl, so a run cannot start until it is installed."
          )
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

  private var builtInSection: some View {
    Section {
      if store.catalog.bundle.isEmpty {
        Text("This build bundles no workflows yet.")
          .foregroundStyle(.secondary)
          .font(.callout)
      }
      ForEach(store.catalog.bundle) { row in
        WorkflowSettingsRowView(row: row, store: store)
      }
    } header: {
      sectionHeader(
        "Built-in",
        detail: "Workflows shipped inside the app. Their ids start with prowl.")
    }
  }

  private var userSection: some View {
    Section {
      if store.catalog.user.isEmpty {
        Text("No workflows yet. Create one from the starter file, or ask an agent to write one.")
          .foregroundStyle(.secondary)
          .font(.callout)
      }
      ForEach(store.catalog.user) { row in
        WorkflowSettingsRowView(row: row, store: store)
      }
      HStack(spacing: 8) {
        Button {
          store.send(.newWorkflowTapped)
        } label: {
          Label("New Workflow…", systemImage: "plus")
        }
        .help("Write a starter workflow file into your workflows folder and reveal it")
        Button("Ask an Agent…") {
          store.send(.askAgentTapped)
        }
        .help("Copy a prompt that asks your coding agent to write a workflow for you")
        Button("Show Folder") {
          store.send(.revealUserFolderTapped)
        }
        .help("Show \(abbreviated(store.catalog.userDirectory)) in Finder")
        Spacer()
      }
    } header: {
      sectionHeader(
        "Your Workflows",
        detail: "YAML files in \(abbreviated(store.catalog.userDirectory)). "
          + "Every enabled, valid file is offered in the Command Palette, the toolbar Agents menu, "
          + "and the Active Agents context menu.")
    }
  }

  @ViewBuilder
  private var repositorySections: some View {
    if store.catalog.repositories.isEmpty {
      Section {
        Text("Files in a repository's .prowl/workflows folder appear here for that repository.")
          .foregroundStyle(.secondary)
          .font(.callout)
      } header: {
        sectionHeader("Repositories", detail: nil)
      }
    }
    ForEach(store.catalog.repositories) { group in
      Section {
        ForEach(group.rows) { row in
          WorkflowSettingsRowView(row: row, store: store)
        }
      } header: {
        sectionHeader(group.name, detail: abbreviated(group.directory))
      }
    }
  }

  private func sectionHeader(_ title: String, detail: String?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
      if let detail {
        Text(detail)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var authoringPromptStrings: AskAgentHelpStrings {
    let resources = SupacodePaths.bundledDocsURL?.deletingLastPathComponent()
    let skill =
      resources?.appending(path: "skills/prowl-workflow/SKILL.md", directoryHint: .notDirectory)
      .path(percentEncoded: false)
      ?? "/Applications/Prowl.app/Contents/Resources/skills/prowl-workflow/SKILL.md"
    let manual =
      SupacodePaths.bundledDocsURL?.appending(path: "components/workflows.md", directoryHint: .notDirectory)
      .path(percentEncoded: false)
      ?? "/Applications/Prowl.app/Contents/Resources/docs/components/workflows.md"
    return WorkflowAuthoringPrompt.strings(
      skillPath: skill,
      manualPath: manual,
      workflowsDirectory: store.catalog.userDirectory.path(percentEncoded: false))
  }

  private func abbreviated(_ url: URL) -> String {
    (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }
}

/// One workflow file: enable checkbox, identity, validation status and diagnostics, and — for
/// workflows with `launch` roles — the bind-mode override and the remembered profile per role.
private struct WorkflowSettingsRowView: View {
  let row: WorkflowSettingsRow
  let store: StoreOf<WorkflowsSettingsFeature>
  @State private var showsDiagnostics = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      titleLine
      if let description = row.description, !description.isEmpty {
        Text(description)
          .foregroundStyle(.secondary)
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
      }
      statusLine
      if !row.diagnostics.isEmpty {
        diagnosticsList
      }
      if !row.launchRoles.isEmpty {
        bindingsBlock
      }
    }
    .onAppear { showsDiagnostics = row.errorCount > 0 }
    .onChange(of: row.errorCount) { _, errorCount in
      if errorCount > 0 { showsDiagnostics = true }
    }
  }

  private var titleLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if let settingsKey = row.settingsKey {
        Toggle(
          "",
          isOn: Binding(
            get: { row.isEnabled },
            set: { store.send(.setEnabled(settingsKey: settingsKey, isEnabled: $0)) })
        )
        .labelsHidden()
        .toggleStyle(.checkbox)
        .help(
          row.isEnabled
            ? "Enabled — offered in the Command Palette and the Agents menu"
            : "Disabled — hidden from every entry point and refused by prowl workflow run")
      } else {
        // A file without an id has nothing to toggle; keep the columns aligned with its siblings.
        Toggle("", isOn: .constant(false))
          .labelsHidden()
          .toggleStyle(.checkbox)
          .hidden()
      }
      Image(systemName: row.icon ?? "point.3.connected.trianglepath.dotted")
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .accessibilityHidden(true)
      Text(row.name)
        .font(.headline)
      if let id = row.workflowID, id != row.name {
        Text(id)
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Reveal") {
        store.send(.revealTapped(rowID: row.id))
      }
      .help("Show \(row.fileName) in Finder")
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  private var statusLine: some View {
    HStack(spacing: 6) {
      statusIcon
      Text(statusText)
      if let shadowNote = row.shadowNote {
        Text("·")
        Text(shadowNote)
          .help("Another definition with the same id is the one that runs; this file is never offered")
      }
      Text("·")
      Text(row.fileName)
        .font(.callout.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
      if !row.diagnostics.isEmpty {
        Button(showsDiagnostics ? "Hide Details" : "Show Details") {
          showsDiagnostics.toggle()
        }
        .buttonStyle(.link)
        .controlSize(.small)
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var statusIcon: some View {
    if !row.isValid {
      Image(systemName: "xmark.octagon.fill")
        .foregroundStyle(.red)
        .accessibilityLabel("Invalid")
    } else if row.warningCount > 0 {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
        .accessibilityLabel("Valid with warnings")
    } else {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityLabel("Valid")
    }
  }

  private var statusText: String {
    if !row.isValid {
      return "\(row.errorCount) error\(row.errorCount == 1 ? "" : "s")"
        + (row.warningCount > 0 ? ", \(row.warningCount) warning\(row.warningCount == 1 ? "" : "s")" : "")
    }
    if row.warningCount > 0 {
      return "Valid, \(row.warningCount) warning\(row.warningCount == 1 ? "" : "s")"
    }
    return "Valid"
  }

  @ViewBuilder
  private var diagnosticsList: some View {
    if showsDiagnostics {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(row.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(location(of: diagnostic))
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .frame(minWidth: 52, alignment: .trailing)
            Text(diagnostic.message)
              .fixedSize(horizontal: false, vertical: true)
            Text(diagnostic.code)
              .font(.callout.monospaced())
              .foregroundStyle(.tertiary)
          }
          .font(.callout)
          .foregroundStyle(diagnostic.severity == .error ? .primary : .secondary)
        }
      }
      .padding(.leading, 24)
    }
  }

  private func location(of diagnostic: WorkflowDiagnostic) -> String {
    guard let location = diagnostic.location else {
      return diagnostic.severity == .error ? "error" : "warning"
    }
    return "\(location.line):\(location.column)"
  }

  private var bindingsBlock: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
      GridRow {
        Text("Bindings")
          .foregroundStyle(.secondary)
        Picker(
          "Bindings",
          selection: Binding(
            get: { row.bindModeOverride },
            set: { mode in
              guard let settingsKey = row.settingsKey else { return }
              store.send(.setBindMode(settingsKey: settingsKey, mode: mode))
            })
        ) {
          Text(followFileLabel).tag(Optional<WorkflowBindModeOverride.Mode>.none)
          Text("Always ask").tag(Optional(WorkflowBindModeOverride.Mode.ask))
          Text("Automatic").tag(Optional(WorkflowBindModeOverride.Mode.auto))
        }
        .labelsHidden()
        .fixedSize()
        .help(
          "Whether the start sheet asks for the profile of each launched role. "
            + "Automatic uses the remembered or suggested profile without asking; the sheet's "
            + "\"Don't ask again\" sets the same value.")
        Button("Manage Profiles…") {
          store.send(.manageProfilesTapped)
        }
        .buttonStyle(.link)
        .help("Open Settings → Agents → Profiles")
      }
      ForEach(row.launchRoles) { role in
        GridRow {
          Text(role.name)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
          rolePicker(role)
            .gridCellColumns(2)
        }
      }
    }
    .font(.callout)
    .padding(.leading, 24)
  }

  private var followFileLabel: String {
    switch row.declaredBind {
    case .ask: "Follow file (ask)"
    case .auto: "Follow file (auto)"
    case nil: "Follow file"
    }
  }

  @ViewBuilder
  private func rolePicker(_ role: WorkflowSettingsRow.LaunchRole) -> some View {
    let available = role.candidates.filter { $0.unavailableReason == nil }
    let remembered = role.candidates.first { $0.profileID == role.rememberedProfileID }
    HStack(spacing: 8) {
      Picker(
        role.name,
        selection: Binding(
          get: { role.rememberedProfileID },
          set: { store.send(.setRememberedBinding(role.memoryKey, profileID: $0)) })
      ) {
        Text("Ask at start").tag(Optional<UUID>.none)
        ForEach(available) { candidate in
          Text("\(candidate.name) — \(candidate.agentToken)").tag(Optional(candidate.profileID))
        }
        if let remembered, remembered.unavailableReason != nil {
          Text("\(remembered.name) — no longer qualifies").tag(Optional(remembered.profileID))
        } else if let rememberedID = role.rememberedProfileID, remembered == nil {
          Text("Missing profile").tag(Optional(rememberedID))
        }
      }
      .labelsHidden()
      .fixedSize()
      .help(
        "The Agent Profile this role launches with. Remembered from the last start; "
          + "\"Ask at start\" forgets it so the sheet asks again.")
      if let reason = remembered?.unavailableReason {
        Text(reason)
          .foregroundStyle(.secondary)
      } else if available.isEmpty {
        Text("No enabled profile qualifies for this role.")
          .foregroundStyle(.secondary)
      }
    }
  }
}
