import ComposableArchitecture
import SwiftUI

/// Settings → Agents → Profiles → native drill-in editor for one profile. The feature
/// owns the alert presentation because its state lives with this destination.
struct AgentProfileEditorView: View {
  @Bindable var store: StoreOf<AgentProfileEditorFeature>
  @State private var isIconPickerPresented = false
  @State private var isHoveringIconTile = false

  var body: some View {
    Form {
      profileSection
      launchPreviewSection
      detailsSection
      advancedSection
      removalSection
    }
    .formStyle(.grouped)
    .navigationTitle(store.profile.name)
    .task { store.send(.task) }
    .alert($store.scope(state: \.alert, action: \.alert))
    .sheet(isPresented: $isIconPickerPresented) {
      TabIconPickerView(
        initialIcon: store.profile.icon,
        defaultIcon: AgentProfileIconResolver.source(for: store.profile.iconSource),
        title: "Agent Icon",
        subtitle: "Pick a preset or enter any SF Symbol name. Clearing restores the runtime brand icon.",
        resetHelp: "Restore the runtime brand icon",
        onApply: { icon in
          store.send(.setIcon(icon))
          isIconPickerPresented = false
        },
        onCancel: { isIconPickerPresented = false }
      )
    }
  }

  private var profileSection: some View {
    Section("Profile") {
      TextField("Name", text: $store.profile.name)
      Picker(
        "Agent",
        selection: Binding(
          get: { store.profile.runtime },
          set: { store.send(.runtimeChanged($0)) }
        )
      ) {
        ForEach(AgentProfileRuntime.allCases) { runtime in
          Text(AgentRuntimeAdapterRegistry.displayName(for: runtime)).tag(runtime)
        }
      }
      iconRow
    }
  }

  private var detailsSection: some View {
    Section("Details") {
      if runtimeAdapter?.supportsModelSelection == true {
        suggestedTextRow(
          title: "Model",
          prompt: "Runtime default",
          text: $store.profile.model,
          suggestions: modelSuggestions
        )
      }
      if runtimeAdapter?.supportsReasoningEffort == true {
        suggestedTextRow(
          title: "Reasoning Effort",
          prompt: "Runtime default",
          text: $store.profile.reasoningEffort,
          suggestions: effortSuggestions
        )
      }
      if let executionModeOptions = runtimeAdapter?.executionModeOptions,
        !executionModeOptions.isEmpty
      {
        Picker("Execution Mode", selection: $store.profile.executionMode) {
          ForEach(executionModeOptions) { mode in
            Text(mode.title).tag(mode)
          }
        }
      }
      switch store.profile.effectiveExecutionMode {
      case .standard:
        EmptyView()
      case .unrestricted:
        Text(
          store.profile.executionMode == .unrestricted
            ? "Requests the runtime's least-restricted mode. "
              + "It may execute commands and modify files without prompting."
            : "Extra arguments request the runtime's least-restricted mode."
        )
        .interfaceFont(.caption)
        .foregroundStyle(.red)
      case .followsExtraArguments:
        Text("Effective execution mode follows your extra arguments.")
          .interfaceFont(.caption)
          .foregroundStyle(.secondary)
      }
      Picker("Open In", selection: $store.profile.placement) {
        Text("New Tab").tag(AgentProfilePlacement.tab)
        Text("New Split").tag(AgentProfilePlacement.split)
      }
      if store.profile.placement == .split {
        Picker("Split Direction", selection: $store.profile.splitDirection) {
          ForEach(UserCustomSplitDirection.allCases) { direction in
            Text(direction.title).tag(direction)
          }
        }
      }
    }
  }

  private var advancedSection: some View {
    Section("Advanced") {
      optionalTextRow(
        title: "Extra Arguments",
        prompt: "--flag value",
        text: Binding(
          get: { store.profile.extraArguments.isEmpty ? nil : store.profile.extraArguments },
          set: { $store.profile.extraArguments.wrappedValue = $0 ?? "" }
        )
      )
      environmentOverridesHeader
      ForEach(store.profile.environmentOverrides) { override in
        environmentOverrideRow(
          environmentOverrideBinding(for: override),
          id: override.id
        )
      }
      if runtimeAdapter?.supportsAccountIsolation == true {
        Toggle("Use Dedicated Home", isOn: $store.profile.bindsDedicatedHome)
          .help("Keep a separate login, usage, and configuration for this profile")
      }
      if runtimeAdapter?.supportsAccountIsolation == true, store.profile.bindsDedicatedHome {
        Text(
          "This profile gets its own runtime home: separate login and usage, "
            + "but also separate skills, global instructions, and session history. "
            + "The first launch signs in through the agent itself."
        )
        .interfaceFont(.caption)
        .foregroundStyle(.secondary)
        LabeledContent(
          "Profile Home",
          value: store.homeInitialized ? "Initialized" : "Not initialized yet"
        )
        Button("Reveal Profile Files") {
          store.send(.revealProfileFiles)
        }
        .help("Open the profile's home folder in Finder")
      }
    }
  }

  private var removalSection: some View {
    Section {
      Button(role: .destructive) {
        store.send(.removeTapped)
      } label: {
        Text("Remove Profile…")
      }
      .help("Remove this profile")
    }
  }

  private var environmentOverridesHeader: some View {
    LabeledContent {
      Button {
        store.send(.addEnvironmentOverride)
      } label: {
        Label("Add Variable", systemImage: "plus")
      }
      .help("Add an environment variable override for this profile's launches")
    } label: {
      Text("Environment Variables")
      Text("Applied only to the launched agent — the pane's shell keeps your normal environment.")
    }
  }

  private func environmentOverrideRow(
    _ override: Binding<AgentProfileEnvironmentOverride>,
    id: AgentProfileEnvironmentOverride.ID
  ) -> some View {
    HStack(spacing: 8) {
      TextField("NAME", text: override.name)
        .interfaceFont(.body, design: .monospaced)
        .frame(width: 180)
        .accessibilityLabel("Variable name")
      TextField("value", text: override.value)
        .interfaceFont(.body, design: .monospaced)
        .accessibilityLabel("Variable value")
      if let issue = AgentProfileEnvironmentPolicy.issue(for: override.wrappedValue) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
          .help(issueDescription(issue))
          .accessibilityLabel(issueDescription(issue))
      }
      Button {
        store.send(.removeEnvironmentOverride(id))
      } label: {
        Label("Remove Variable", systemImage: "minus.circle")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.plain)
      .help("Remove this environment variable")
    }
  }

  private func environmentOverrideBinding(
    for override: AgentProfileEnvironmentOverride
  ) -> Binding<AgentProfileEnvironmentOverride> {
    Binding(
      get: {
        store.profile.environmentOverrides.first { $0.id == override.id } ?? override
      },
      set: { updatedOverride in
        var overrides = store.profile.environmentOverrides
        guard let index = overrides.firstIndex(where: { $0.id == override.id }) else { return }
        overrides[index] = updatedOverride
        $store.profile.environmentOverrides.wrappedValue = overrides
      }
    )
  }

  private func issueDescription(_ issue: AgentProfileEnvironmentPolicy.RowIssue) -> String {
    switch issue {
    case .invalidName:
      "Not a valid environment variable name — this row is ignored at launch."
    case .reservedName:
      "Reserved by Prowl — this row is ignored at launch."
    case .invalidValue:
      "The value contains an unsupported character — this row is ignored at launch."
    }
  }

  private var launchPreviewSection: some View {
    Section("Launch Preview") {
      Text(
        "Prowl types this command into the new pane. "
          + "Override values travel in hidden PROWL_ENV variables, never in the command text."
      )
      .interfaceFont(.caption)
      .foregroundStyle(.secondary)
      Text(previewText)
        .interfaceFont(.callout, design: .monospaced)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .lineLimit(nil)
    }
  }

  private var iconRow: some View {
    HStack(alignment: .center, spacing: 12) {
      iconMenu
      VStack(alignment: .leading, spacing: 4) {
        Text("Icon")
          .interfaceFont(.headline)
        Text(
          store.profile.icon == nil
            ? "\(AgentRuntimeAdapterRegistry.displayName(for: store.profile.runtime)) brand icon"
            : "Custom SF Symbol"
        )
        .interfaceFont(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
  }

  private var iconMenu: some View {
    Menu {
      Button("Choose Symbol…") {
        isIconPickerPresented = true
      }
      if store.profile.icon != nil {
        Divider()
        Button("Clear Icon", role: .destructive) {
          store.send(.setIcon(nil))
        }
      }
    } label: {
      iconPreviewTile
    }
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.accentColor.opacity(isHoveringIconTile ? 0.65 : 0), lineWidth: 1.5)
    }
    .onHover { isHoveringIconTile = $0 }
    .pointerStyle(.link)
    .animation(.easeOut(duration: 0.12), value: isHoveringIconTile)
    .help("Click the icon preview to choose an SF Symbol")
  }

  private var iconPreviewTile: some View {
    AgentProfileIconImage(source: store.profile.iconSource, pointSize: 22)
      .frame(width: 40, height: 40)
      .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 8))
      .contentShape(.rect(cornerRadius: 8))
      .accessibilityLabel("Agent icon picker")
  }

  private func optionalTextRow(
    title: String,
    prompt: String,
    text: Binding<String?>
  ) -> some View {
    LabeledContent(title) {
      TextField("", text: optionalTextBinding(for: text), prompt: Text(prompt))
        .accessibilityLabel(title)
    }
  }

  private func suggestedTextRow(
    title: String,
    prompt: String,
    text: Binding<String?>,
    suggestions: [String]
  ) -> some View {
    let selection = suggestionSelection(for: text, suggestions: suggestions)
    return LabeledContent(title) {
      HStack(spacing: 4) {
        TextField("", text: optionalTextBinding(for: text), prompt: Text(prompt))
          .accessibilityLabel(title)
        Picker("", selection: selection) {
          Text("Runtime Default").tag(AgentProfileSuggestionSelection.runtimeDefault)
          ForEach(suggestions, id: \.self) { suggestion in
            Text(suggestion).tag(AgentProfileSuggestionSelection.suggestion(suggestion))
          }
          if case .custom = selection.wrappedValue {
            Text("Custom Value").tag(selection.wrappedValue)
          }
        }
        .labelsHidden()
        .frame(width: 28)
        .padding(.trailing, 4)
        .accessibilityLabel("\(title) suggestions")
        .help("Pick a known value, or type any value.")
      }
    }
  }

  private func optionalTextBinding(for text: Binding<String?>) -> Binding<String> {
    Binding(
      get: { text.wrappedValue ?? "" },
      set: { value in
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        text.wrappedValue = trimmed.isEmpty ? nil : value
      }
    )
  }

  private func suggestionSelection(
    for text: Binding<String?>,
    suggestions: [String]
  ) -> Binding<AgentProfileSuggestionSelection> {
    Binding(
      get: { AgentProfileSuggestionSelection(value: text.wrappedValue, suggestions: suggestions) },
      set: { text.wrappedValue = $0.value }
    )
  }

  private var previewText: String {
    let plan = try? AgentProfileLaunchPlanner.plan(
      for: store.profile,
      homeBaseDirectory: SupacodePaths.agentProfileHomesDirectory
    )
    return plan?.previewText ?? "Unavailable"
  }

  private var effortSuggestions: [String] {
    runtimeAdapter?.reasoningEffortSuggestions ?? []
  }

  private var modelSuggestions: [String] {
    runtimeAdapter?.modelSuggestions ?? []
  }

  private var runtimeAdapter: (any AgentRuntimeAdapter)? {
    AgentRuntimeAdapterRegistry.profileAdapter(for: store.profile.runtime)
  }
}
