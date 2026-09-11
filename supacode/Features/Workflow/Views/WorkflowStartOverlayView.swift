// supacode/Features/Workflow/Views/WorkflowStartOverlayView.swift
// The workflow start sheet (docs-ai 063 C2): a centered card that explains who takes part and
// what will happen, and collects the choices a run needs before it exists. Every choice is
// sent as a typed action; the reducer owns eligibility (011 decision 1) and the view renders
// its answers. Sections mirror the Workflow History panel: roles, options, steps.

import AppKit
import ComposableArchitecture
import ProwlCLIShared
import SwiftUI

struct WorkflowStartOverlayView: View {
  let store: StoreOf<WorkflowStartFeature>

  var body: some View {
    ZStack {
      Color.clear
        .contentShape(.rect)
        .onTapGesture {
          store.send(.cancelTapped)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Dismiss Workflow Start")

      GeometryReader { geometry in
        VStack {
          WorkflowStartCard(store: store)
            .zIndex(1)
          Spacer(minLength: 0)
        }
        .padding(.top, max(0, geometry.size.height * 0.12))
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
      }
    }
    .sheet(
      isPresented: Binding(
        get: { store.bundleReview != nil }, set: { if !$0 { store.send(.dismissBundleReview) } })
    ) {
      WorkflowBundleReviewView(
        review: store.bundleReview, selectFile: { store.send(.reviewFileSelected($0)) },
        approve: { store.send(.approveBundleTapped) }, reveal: { store.send(.revealBundleTapped) },
        close: { store.send(.dismissBundleReview) })
    }
  }
}

private struct WorkflowStartCard: View {
  let store: StoreOf<WorkflowStartFeature>

  var body: some View {
    let plan = store.plan
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if let failure = store.context.cliServiceFailure {
            socketBanner(failure)
          } else if !store.cliInstalled {
            cliBanner
          }
          if store.requiresBundleApproval {
            bundleApprovalBanner
          }
          choicesForm(plan)
          if !plan.steps.isEmpty {
            stepsSection(plan)
          }
          if !store.visibleSkipOptions.isEmpty {
            skipSection
          }
          if let error = store.submissionError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.callout)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(16)
      }
      .frame(maxHeight: 460)
      Divider()
      footer
    }
    .frame(maxWidth: 580)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    .shadow(radius: 32, x: 0, y: 12)
    .padding(16)
    .background {
      // Pull the keyboard away from the terminal once when the sheet appears, so Esc and
      // Return reach the sheet. This anchor never re-grabs the keyboard:
      // the sheet hosts text fields, and a focused field must keep the keyboard.
      WorkflowStartKeyAnchor(
        onEscape: { store.send(.cancelTapped) },
        onReturn: { store.send(.runTapped) }
      )
    }
  }

  // MARK: - Header and banners

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      WorkflowIconImage(icon: store.context.item.icon, pointSize: 22)
        .frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(store.context.item.name)
            .font(.headline)
          Spacer(minLength: 8)
          Label(store.context.worktreeName, systemImage: "arrow.triangle.branch")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help("This run works in the \(store.context.worktreeName) worktree.")
        }
        if let description = store.context.item.workflowDescription, !description.isEmpty {
          Text(description)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var cliBanner: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Label(
          "Workflows need the prowl command line tool.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
        Spacer()
        if let title = store.context.cliInstallActionTitle {
          Button(title) {
            store.send(.installCLITapped)
          }
          .help("\(title) the prowl command line tool at /usr/local/bin/prowl.")
        }
      }
      Text(store.context.cliInstallBlockerCopy)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.callout)
  }

  /// Prowl is not listening for `prowl`, so participants could not deliver; the reason names
  /// the fix (nothing to install here).
  private func socketBanner(_ failure: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("Prowl is not listening for the prowl command.", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(failure)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.callout)
  }

  private var bundleApprovalBanner: some View {
    HStack(spacing: 8) {
      Label("Review this script bundle before running it.", systemImage: "checkmark.shield")
      Spacer()
      Button("Review Bundle…") { store.send(.reviewBundleTapped) }
        .help("Inspect the bundle and approve this version; approval does not start the workflow")
    }
    .font(.callout)
  }

  // MARK: - Sections

  /// Both columns are leading-aligned: names on the left edge of a fixed label column,
  /// controls sized to their content on the left edge of the control column, whose width
  /// caps a long pane title so it truncates instead of moving the layout.
  private static let labelWidth: CGFloat = 150
  private static let controlWidth: CGFloat = 320

  private func sectionHeader(_ title: String, help: String) -> some View {
    Text(title)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      .help(help)
  }

  /// One label/control row: the name in the label column, the choice in the control column.
  private func formRow<Label: View, Control: View>(
    @ViewBuilder label: () -> Label, @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      label()
        .frame(width: Self.labelWidth, alignment: .leading)
      control()
        .frame(maxWidth: Self.controlWidth, alignment: .leading)
      Spacer(minLength: 0)
    }
  }

  private func choicesForm(_ plan: WorkflowStartPlan) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      if !plan.roles.isEmpty {
        sectionHeader("Roles", help: "Who takes part in this run. Hover a role for what it does.")
        ForEach(plan.roles) { role in
          roleRow(role)
        }
      }
      if !store.context.definition.inputs.isEmpty {
        sectionHeader("Options", help: "Choices this workflow asks for before it starts.")
          .padding(.top, plan.roles.isEmpty ? 0 : 10)
        ForEach(store.context.definition.inputs, id: \.name) { input in
          inputRow(input)
        }
      }
    }
  }

  private func roleRow(_ role: WorkflowStartPlan.Role) -> some View {
    let required = store.state.isRoleRequired(role.name)
    let launch = store.context.launchRoles.first { $0.name == role.name }
    return formRow {
      Label(role.title, systemImage: roleSymbol(role))
        .labelStyle(.titleAndIcon)
        .foregroundStyle(required ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .lineLimit(1)
        .truncationMode(.tail)
        .help(roleHelp(role, required: required))
        .accessibilityLabel("\(role.title), \(role.kindLabel)")
    } control: {
      VStack(alignment: .leading, spacing: 6) {
        roleControl(role, required: required)
        if role.source == .current, store.selectedSourceIsBareShell, store.sourceRequiresAgent {
          Text("Choose a pane with a running agent.")
            .font(.footnote)
            .foregroundStyle(.orange)
            .help("A step sends this role instructions, so its pane must host a detected agent.")
        }
        if required, let launch {
          if !store.state.candidates(for: launch).contains(where: { $0.unavailableReason == nil }) {
            Text(
              "No profile can run this role. Check its agent requirements and Settings → Agents → Profiles, "
                + "then reopen this setup."
            )
            .font(.footnote)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
          }
          if let note = launch.rejectedNote {
            Text(note)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          if store.state.canCreateSuggestion(for: role.name), store.creatingSuggestionForRole != role.name {
            Button("Create profile from suggestion…") {
              store.send(.createSuggestionTapped(role: role.name))
            }
            .buttonStyle(.link)
            .font(.callout)
            .help("Create a profile from this workflow's suggested agent configuration.")
          }
          if store.creatingSuggestionForRole == role.name {
            suggestionConfirmBlock(launch)
          }
        }
      }
    }
  }

  private func roleSymbol(_ role: WorkflowStartPlan.Role) -> String {
    switch role.source {
    case .current: "terminal"
    case .launch: "plus.app"
    case .pick: "person.crop.square"
    }
  }

  /// Everything the row used to spell out, on hover: the kind of pane, the steps that address
  /// the role, where a launched pane opens, and why an unreached role takes no choice.
  private func roleHelp(_ role: WorkflowStartPlan.Role, required: Bool) -> String {
    var lines = ["\(role.kindLabel) — \(role.kindDescription)"]
    if let steps = role.stepsCaption { lines.append(steps) }
    if required, let placement = role.placementNote { lines.append(placement) }
    if !required { lines.append("Not started with the current options.") }
    return lines.joined(separator: "\n")
  }

  @ViewBuilder
  private func roleControl(_ role: WorkflowStartPlan.Role, required: Bool) -> some View {
    switch role.source {
    case .current:
      if let source = store.context.source {
        if source.isPreselectionFixed,
          let fixed = source.candidates.first(where: { $0.surfaceID == source.preselectedSurfaceID })
        {
          Text(paneLabel(fixed))
            .lineLimit(1)
            .truncationMode(.middle)
            .help("Started from this pane's Active Agents row, so it is the source.")
        } else {
          Picker(selection: sourceBinding) {
            ForEach(source.candidates) { candidate in
              Text(paneLabel(candidate)).tag(candidate.surfaceID as UUID?)
            }
          } label: {
            Text(role.title)
          }
          .labelsHidden()
          .frame(maxWidth: Self.controlWidth, alignment: .leading)
          .help("The pane this run starts from.")
        }
      }
    case .launch:
      if required, let launch = store.context.launchRoles.first(where: { $0.name == role.name }) {
        Picker(selection: launchBinding(role: role.name)) {
          Text("Choose a profile…").tag(nil as UUID?)
          ForEach(store.state.candidates(for: launch)) { candidate in
            if let reason = candidate.unavailableReason {
              // Contract: unavailable rows are dimmed with their reason and cannot be chosen.
              Text("\(candidate.name) — \(reason)")
                .foregroundStyle(.secondary)
                .tag(candidate.profileID as UUID?)
                .selectionDisabled()
            } else {
              Text(candidate.name).tag(candidate.profileID as UUID?)
            }
          }
        } label: {
          Text(role.title)
        }
        .labelsHidden()
        .frame(maxWidth: Self.controlWidth, alignment: .leading)
        .help("The Agent Profile Prowl starts for this role.")
      } else {
        Text("Not used")
          .foregroundStyle(.tertiary)
          .help("The current options never reach this role, so no agent is started for it.")
      }
    case .pick:
      if let pick = store.context.pickRoles.first(where: { $0.name == role.name }) {
        Picker(selection: pickBinding(role: role.name)) {
          Text("Choose a pane…").tag(nil as UUID?)
          ForEach(pick.candidates.filter { $0.surfaceID != store.selectedSourceSurfaceID }) { candidate in
            Text(paneLabel(candidate)).tag(candidate.surfaceID as UUID?)
          }
        } label: {
          Text(role.title)
        }
        .labelsHidden()
        .frame(maxWidth: Self.controlWidth, alignment: .leading)
        .help("An agent already running in this worktree takes this role.")
      }
    }
  }

  private func suggestionConfirmBlock(_ role: WorkflowStartLaunchRole) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("Profile name", text: suggestionNameBinding)
      if let suggestion = role.suggestion {
        Text(suggestionSummary(suggestion))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Cancel") {
          store.send(.createSuggestionCancelled)
        }
        .help("Close without creating a profile.")
        Button("Create") {
          store.send(.createSuggestionConfirmed)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(store.suggestionProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
        .help("Create this profile and select it for the role. Manage it later in Settings.")
      }
    }
    .padding(10)
    .frame(width: Self.controlWidth)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
  }

  private func inputRow(_ input: WorkflowInputDefinition) -> some View {
    formRow {
      Text(input.prompt ?? WorkflowStartPlan.title(for: input.name))
        .lineLimit(2)
        .multilineTextAlignment(.trailing)
        .help(inputHelp(input))
    } control: {
      Group {
        if !input.values.isEmpty {
          Picker(input.name, selection: inputBinding(name: input.name)) {
            if input.defaultValue == nil {
              Text("Choose…").tag("")
            }
            ForEach(input.values, id: \.self) { value in
              Text(value).tag(value)
            }
          }
          .labelsHidden()
        } else {
          TextField(
            input.name, text: inputBinding(name: input.name),
            prompt: Text(input.defaultValue == nil ? "Required" : ""))
        }
      }
      .frame(maxWidth: Self.controlWidth, alignment: .leading)
      .help(inputHelp(input))
    }
  }

  private func inputHelp(_ input: WorkflowInputDefinition) -> String {
    var text = "Input “\(input.name)”"
    if let value = input.defaultValue { text += " · default \(value.stringValue)" } else { text += " · required" }
    if let prompt = input.prompt { text += "\n\(prompt)" }
    return text
  }

  private func stepsSection(_ plan: WorkflowStartPlan) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader("Steps", help: "What the run does, in order. Hover a step for details.")
      VStack(alignment: .leading, spacing: 6) {
        ForEach(plan.steps) { step in
          stepRow(step)
        }
      }
    }
  }

  private func stepRow(_ step: WorkflowStartPlan.Step) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(step.number, format: .number)
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 18, alignment: .trailing)
      Image(systemName: stepSymbol(step))
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .accessibilityHidden(true)
      Text(step.title)
        .lineLimit(1)
        .truncationMode(.tail)
      if step.context != .always {
        Image(systemName: step.context == .conditional ? "arrow.triangle.branch" : "repeat")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .accessibilityLabel(step.context == .conditional ? "Conditional" : "Repeats")
      }
      Spacer(minLength: 8)
      if let role = step.roleTitle {
        Text(role)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .opacity(step.context == .always ? 1 : 0.75)
    .help(stepHelp(step))
  }

  private func stepSymbol(_ step: WorkflowStartPlan.Step) -> String {
    switch step.verb {
    case "message": "text.bubble"
    case "launch": "play.circle"
    case "action": "gearshape"
    case "notify": "bell"
    case "close": "xmark.circle"
    default: "circle"
    }
  }

  private func stepHelp(_ step: WorkflowStartPlan.Step) -> String {
    let verb =
      switch step.verb {
      case "message": "Sends instructions to \(step.roleTitle ?? "a role") and waits for its reply."
      case "launch": "Starts the \(step.roleTitle ?? "launch") agent with its first instructions."
      case "action": "Runs an action inside Prowl."
      case "notify": "Sends a Prowl notification."
      case "close": "Closes the \(step.roleTitle ?? "role")'s pane."
      default: step.verb
      }
    switch step.context {
    case .always: return verb
    case .conditional: return "\(verb) Runs only when its branch is chosen."
    case .repeated: return "\(verb) Runs once per loop iteration."
    }
  }

  private var skipSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader("Optional Steps", help: "Steps the run can start without.")
      ForEach(store.visibleSkipOptions, id: \.stepID) { option in
        Toggle("Skip \(option.title ?? option.stepID)", isOn: skipBinding(stepID: option.stepID))
          .help(consequenceText(store.state.skipConsequence(for: option.stepID)) ?? "Start the run without this step.")
      }
    }
  }

  private var footer: some View {
    HStack {
      if store.showsDontAskAgain {
        Toggle("Don't ask again", isOn: dontAskAgainBinding)
          .help("Start this workflow without the sheet whenever nothing needs a decision.")
      }
      Spacer()
      Button("Cancel") {
        store.send(.cancelTapped)
      }
      .keyboardShortcut(.cancelAction)
      .help("Close without starting the workflow (Esc).")
      Button(store.isSubmitting ? "Starting…" : "Run") {
        store.send(.runTapped)
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!store.canRun)
      .help("Start the workflow (Return).")
    }
    .padding(12)
  }

  // MARK: - Labels

  /// "claude in p12" for an agent pane; a bare shell is named by the worktree, not by the
  /// shell's host-and-path title.
  private func paneLabel(_ candidate: WorkflowStartPaneCandidate) -> String {
    let handle = candidate.handle.map { " in \($0)" } ?? ""
    guard let agent = candidate.agentDisplayName, candidate.agentToken != nil else {
      return "\(store.context.worktreeName)\(handle) (no agent)"
    }
    return "\(agent)\(handle)"
  }

  private func suggestionSummary(_ suggestion: WorkflowProfileSuggestion) -> String {
    var parts: [String] = []
    if let agent = suggestion.agent { parts.append(agent) }
    if let model = suggestion.model { parts.append("model \(model)") }
    if let effort = suggestion.reasoningEffort { parts.append("\(effort) effort") }
    if let mode = suggestion.executionMode { parts.append("\(mode) mode") }
    return "Suggested by the workflow: " + parts.joined(separator: " · ")
  }

  private func consequenceText(_ consequence: WorkflowSkipConsequence?) -> String? {
    switch consequence {
    case .continues(let optional) where !optional.isEmpty:
      return "The run continues; \(optional.joined(separator: ", ")) proceeds without this delivery."
    case .endsRun, .continues, .noDelivery, nil:
      return nil
    }
  }

  // MARK: - Bindings

  private var sourceBinding: Binding<UUID?> {
    Binding(
      get: { store.selectedSourceSurfaceID },
      set: { store.send(.sourceSelected($0)) }
    )
  }

  private func launchBinding(role: String) -> Binding<UUID?> {
    Binding(
      get: { store.launchSelections[role] },
      set: { store.send(.launchProfileSelected(role: role, profileID: $0)) }
    )
  }

  private func pickBinding(role: String) -> Binding<UUID?> {
    Binding(
      get: { store.pickSelections[role] },
      set: { store.send(.pickPaneSelected(role: role, surfaceID: $0)) }
    )
  }

  private func inputBinding(name: String) -> Binding<String> {
    Binding(
      get: { store.inputValues[name] ?? "" },
      set: { store.send(.inputChanged(name: name, value: $0)) }
    )
  }

  private func skipBinding(stepID: String) -> Binding<Bool> {
    Binding(
      get: { store.skippedSteps.contains(stepID) },
      set: { _ in store.send(.skipToggled(stepID: stepID)) }
    )
  }

  private var dontAskAgainBinding: Binding<Bool> {
    Binding(
      get: { store.dontAskAgain },
      set: { store.send(.dontAskAgainToggled($0)) }
    )
  }

  private var suggestionNameBinding: Binding<String> {
    Binding(
      get: { store.suggestionProfileName },
      set: { store.send(.suggestionNameChanged($0)) }
    )
  }
}

extension WorkflowStartFeature.State {
  /// The toggle appears exactly when a launch role would ask again next time (011 decision 5).
  var showsDontAskAgain: Bool {
    requiredLaunchRoles.contains { $0.effectiveBind == .ask } || dontAskAgain
  }

  var selectedSourceIsBareShell: Bool {
    guard let source = context.source,
      let selected = selectedSourceSurfaceID,
      let candidate = source.candidates.first(where: { $0.surfaceID == selected })
    else { return false }
    return candidate.agentToken == nil
  }
}

private struct WorkflowStartKeyAnchor: NSViewRepresentable {
  let onEscape: () -> Void
  let onReturn: () -> Void

  func makeNSView(context: Context) -> AnchorNSView {
    let view = AnchorNSView()
    view.onEscape = onEscape
    view.onReturn = onReturn
    return view
  }

  func updateNSView(_ nsView: AnchorNSView, context: Context) {
    nsView.onEscape = onEscape
    nsView.onReturn = onReturn
  }

  final class AnchorNSView: NSView {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    private var didGrabFocus = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard !didGrabFocus, let window else { return }
      didGrabFocus = true
      window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
      switch event.keyCode {
      case 53:  // escape
        onEscape?()
      case 36, 76:  // return, keypad enter
        onReturn?()
      default:
        super.keyDown(with: event)
      }
    }
  }
}
