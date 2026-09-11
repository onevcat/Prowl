import ComposableArchitecture
import SwiftUI

/// Settings › Workflows › "New Workflow…": name and id the bundle, pick a starter shape, or
/// hand the job to an agent. Writing the file is the reducer's `createWorkflowTapped`.
struct NewWorkflowSheet: View {
  @Bindable var store: StoreOf<WorkflowsSettingsFeature>
  @State private var isIconPickerPresented = false
  @FocusState private var nameFieldFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      Form {
        identitySection
        starterSection
      }
      .formStyle(.grouped)
      Divider()
      footer
    }
    .frame(width: 560, height: 520)
    .onAppear { nameFieldFocused = true }
    .sheet(isPresented: $isIconPickerPresented) {
      TabIconPickerView(
        initialIcon: store.newWorkflow?.icon.isEmpty == false ? store.newWorkflow?.icon : nil,
        defaultIcon: TabIconSource(systemSymbol: "point.3.connected.trianglepath.dotted"),
        title: "Workflow Icon",
        subtitle: "Pick a preset or enter any SF Symbol name. The icon marks this workflow in menus and the palette.",
        resetHelp: "Use the default workflow icon",
        onApply: { icon in
          store.send(.newWorkflowIconChanged(icon ?? ""))
          isIconPickerPresented = false
        },
        onCancel: { isIconPickerPresented = false }
      )
    }
    .sheet(
      isPresented: Binding(
        get: { store.newWorkflow?.showsAuthoringPrompt == true },
        set: { store.send(.setAuthoringPromptPresented($0)) })
    ) {
      AskAgentHelpView(strings: workflowAuthoringPromptStrings(directory: store.workflowDirectory)) {
        store.send(.setAuthoringPromptPresented(false))
      }
    }
  }

  private var identitySection: some View {
    Section {
      HStack(alignment: .top, spacing: 12) {
        iconTile
        VStack(alignment: .leading, spacing: 8) {
          TextField("Name", text: nameBinding, prompt: Text("Daily Check"))
            .focused($nameFieldFocused)
            .help("Shown in the Command Palette, the Agents menu, and Workflow History")
          LabeledContent("ID") {
            TextField("ID", text: idBinding, prompt: Text("daily-check"))
              .font(.body.monospaced())
              .labelsHidden()
              .help("Lowercase slug used by `prowl workflow run` and as the bundle folder name")
          }
          Text(idCaption)
            .font(.caption)
            .foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    } header: {
      Text("New Workflow")
        .font(.headline)
    }
  }

  private var iconTile: some View {
    Button {
      isIconPickerPresented = true
    } label: {
      WorkflowIconImage(icon: store.newWorkflow?.icon.isEmpty == false ? store.newWorkflow?.icon : nil, pointSize: 22)
        .frame(width: 44, height: 44)
        .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 8))
        .contentShape(.rect(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .pointerStyle(.link)
    .help("Choose an SF Symbol for this workflow (optional)")
    .accessibilityLabel("Workflow icon")
  }

  private var starterSection: some View {
    Section {
      ForEach(WorkflowStarterTemplate.Kind.allCases, id: \.self) { kind in
        starterRow(kind)
      }
    } header: {
      Text("Starter")
    } footer: {
      Text(
        "Both starters are small, valid workflows with comments that explain every field, "
          + "so you can grow them into your own. Prefer an agent to write it for you? Use Create with Agent.")
    }
  }

  private func starterRow(_ kind: WorkflowStarterTemplate.Kind) -> some View {
    let selected = store.newWorkflow?.kind == kind
    return Button {
      store.send(.newWorkflowKindChanged(kind))
    } label: {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
          .font(.title3)
          .accessibilityHidden(true)
        Image(systemName: kind.symbol)
          .font(.title3)
          .foregroundStyle(.secondary)
          .frame(width: 24)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(kind.title)
            .font(.body.weight(.medium))
          Text(kind.summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(kind.examples)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 4)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .help(kind.starterDescription)
  }

  private var footer: some View {
    HStack {
      Button("Create with Agent…") { store.send(.askAgentTapped) }
        .help("Copy a prompt that asks your coding agent to write this workflow for you")
      Spacer()
      Button("Cancel") { store.send(.dismissNewWorkflow) }
        .keyboardShortcut(.cancelAction)
        .help("Close without creating a workflow (Esc)")
      Button("Create") { store.send(.createWorkflowTapped) }
        .keyboardShortcut(.defaultAction)
        .disabled(problem != nil)
        .help(problem ?? "Write the starter bundle and open it in your default YAML editor (Return)")
    }
    .padding(12)
  }

  private var problem: String? { store.newWorkflowProblem }

  private var idCaption: String {
    if let problem, store.newWorkflow?.name.isEmpty == false { return problem }
    let folder = (store.workflowDirectory.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    let file = store.newWorkflow?.request.fileName ?? "<id>.pwlworkflow"
    return "Creates \(folder)/\(file)/workflow.yaml"
  }

  private var nameBinding: Binding<String> {
    Binding(
      get: { store.newWorkflow?.name ?? "" },
      set: { store.send(.newWorkflowNameChanged($0)) })
  }

  private var idBinding: Binding<String> {
    Binding(
      get: { store.newWorkflow?.id ?? "" },
      set: { store.send(.newWorkflowIDChanged($0)) })
  }
}

extension WorkflowStarterTemplate.Kind {
  var title: String {
    switch self {
    case .singleAgent: "Single agent"
    case .multiAgent: "Multi-agent"
    }
  }

  var symbol: String {
    switch self {
    case .singleAgent: "text.bubble"
    case .multiAgent: "person.2"
    }
  }

  var summary: String {
    switch self {
    case .singleAgent:
      "A prompt template. Prowl sends one instruction to the agent in the current pane and collects its answer."
    case .multiAgent:
      "Several agents that hand results to each other. Prowl launches or picks the other agents for each role."
    }
  }

  var examples: String {
    switch self {
    case .singleAgent:
      "Examples: summarize the diff, draft a commit message, run the tests and report."
    case .multiAgent:
      "Examples: hand off to a fresh agent, cross review, adversarial review."
    }
  }

  var starterDescription: String {
    switch self {
    case .singleAgent:
      "The starter asks the current agent for today's date in a chosen style."
    case .multiAgent:
      "The starter plays rock-paper-scissors: the current agent picks a move, "
        + "a second agent answers with the winning one."
    }
  }
}
