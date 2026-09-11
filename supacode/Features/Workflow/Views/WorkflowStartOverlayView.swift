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
        VStack(alignment: .leading, spacing: 18) {
          if let failure = store.context.cliServiceFailure {
            socketBanner(failure)
          } else if !store.cliInstalled {
            cliBanner
          }
          if store.requiresBundleApproval {
            bundleApprovalBanner
          }
          rolesSection(plan)
          if !store.context.definition.inputs.isEmpty {
            optionsSection
          }
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

  private func sectionHeader(_ title: String, hint: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.subheadline.weight(.semibold))
      Spacer(minLength: 8)
      Text(hint)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  private func groupBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0, content: content)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
  }

  private func rolesSection(_ plan: WorkflowStartPlan) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader("Roles", hint: "Who takes part, and which pane or agent serves each role")
      groupBox {
        ForEach(Array(plan.roles.enumerated()), id: \.element.id) { index, role in
          if index > 0 { Divider().padding(.leading, 12) }
          roleRow(role)
        }
      }
    }
  }

  @ViewBuilder
  private func roleRow(_ role: WorkflowStartPlan.Role) -> some View {
    let required = store.state.isRoleRequired(role.name)
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(role.title)
              .font(.body.weight(.medium))
            Text(role.kindLabel)
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(.quaternary, in: Capsule())
              .help(role.kindDescription)
          }
          if let caption = roleCaption(role, required: required) {
            Text(caption)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        Spacer(minLength: 12)
        roleControl(role, required: required)
      }
      if role.source == .current, store.selectedSourceIsBareShell, store.sourceRequiresAgent {
        Text("A step sends instructions to this role, so the pane must host a detected agent.")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
      if role.source == .launch, let launch = store.context.launchRoles.first(where: { $0.name == role.name }) {
        if let note = launch.rejectedNote {
          Text(note)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if required, store.state.canCreateSuggestion(for: role.name), store.creatingSuggestionForRole != role.name {
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
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .opacity(required ? 1 : 0.6)
  }

  private func roleCaption(_ role: WorkflowStartPlan.Role, required: Bool) -> String? {
    var parts: [String] = []
    if !required {
      parts.append("Not started with the current options")
    }
    if let steps = role.stepsCaption { parts.append(steps) }
    if required, let placement = role.placementNote { parts.append(placement) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            .foregroundStyle(.secondary)
            .help("This workflow was started from the Active Agents row, so its pane is the source.")
        } else {
          Picker(selection: sourceBinding) {
            ForEach(source.candidates) { candidate in
              Text(paneLabel(candidate)).tag(candidate.surfaceID as UUID?)
            }
          } label: {
            Text(role.title)
          }
          .labelsHidden()
          .fixedSize()
          .help("The pane this workflow runs from — the CLI's [source] argument.")
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
        .fixedSize()
        .help("The Agent Profile Prowl launches for the \(role.name) role.")
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
        .fixedSize()
        .help("An agent already running in this worktree takes the \(role.name) role.")
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
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
  }

  private var optionsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader("Options", hint: "Choices this workflow asks for")
      groupBox {
        ForEach(Array(store.context.definition.inputs.enumerated()), id: \.element.name) { index, input in
          if index > 0 { Divider().padding(.leading, 12) }
          inputRow(input)
        }
      }
    }
  }

  private func inputRow(_ input: WorkflowInputDefinition) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(input.prompt ?? WorkflowStartPlan.title(for: input.name))
          .fixedSize(horizontal: false, vertical: true)
        if input.prompt != nil || input.defaultValue == nil {
          Text(input.defaultValue == nil ? "\(input.name) · required" : input.name)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 12)
      if !input.values.isEmpty {
        Picker(input.name, selection: inputBinding(name: input.name)) {
          ForEach(input.values, id: \.self) { value in
            Text(value).tag(value)
          }
        }
        .labelsHidden()
        .fixedSize()
        .help(input.prompt ?? "The \(input.name) input.")
      } else {
        TextField(input.name, text: inputBinding(name: input.name), prompt: Text(input.type == .integer ? "0" : "…"))
          .textFieldStyle(.roundedBorder)
          .frame(width: 200)
          .help(input.prompt ?? "The \(input.name) input.")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private func stepsSection(_ plan: WorkflowStartPlan) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader("Steps", hint: "What the run does, in order")
      VStack(alignment: .leading, spacing: 4) {
        ForEach(plan.steps) { step in
          stepRow(step)
        }
      }
      .padding(.horizontal, 4)
    }
  }

  private func stepRow(_ step: WorkflowStartPlan.Step) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(step.number, format: .number)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 18, alignment: .trailing)
      Image(systemName: stepSymbol(step))
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 14)
        .accessibilityHidden(true)
      Text(step.title)
        .lineLimit(1)
        .truncationMode(.tail)
      if let note = stepNote(step) {
        Text(note)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      if let role = step.roleTitle {
        Text(role)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .font(.callout)
    .opacity(step.context == .always ? 1 : 0.7)
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

  private func stepNote(_ step: WorkflowStartPlan.Step) -> String? {
    switch step.context {
    case .always: nil
    case .conditional: "if a condition holds"
    case .repeated: "may repeat"
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
      sectionHeader("Optional Steps", hint: "Start the run without these")
      groupBox {
        ForEach(Array(store.visibleSkipOptions.enumerated()), id: \.element.stepID) { index, option in
          if index > 0 { Divider().padding(.leading, 12) }
          VStack(alignment: .leading, spacing: 2) {
            Toggle(
              "Skip \(option.title ?? option.stepID)",
              isOn: skipBinding(stepID: option.stepID)
            )
            .help("Start the run without this step.")
            if let text = consequenceText(store.state.skipConsequence(for: option.stepID)) {
              Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
        }
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

  private func paneLabel(_ candidate: WorkflowStartPaneCandidate) -> String {
    let name = candidate.agentDisplayName ?? candidate.paneTitle
    let handle = candidate.handle.map { " in \($0)" } ?? ""
    let shell = candidate.agentToken == nil ? " (no agent)" : ""
    return "\(name)\(handle)\(shell)"
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
