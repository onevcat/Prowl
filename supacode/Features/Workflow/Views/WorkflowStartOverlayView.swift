// supacode/Features/Workflow/Views/WorkflowStartOverlayView.swift
// The workflow start sheet (docs-ai 063 C2): the handoff HUD's centered card pattern hosting
// source/role/input collection before a run exists. Every choice is sent as a typed action;
// the reducer owns eligibility (011 decision 1) and the view renders its answers.

import AppKit
import ComposableArchitecture
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
        .padding(.top, max(0, geometry.size.height * 0.16))
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
      }
    }
  }
}

private struct WorkflowStartCard: View {
  let store: StoreOf<WorkflowStartFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if let failure = store.context.cliServiceFailure {
            socketBanner(failure)
          } else if !store.cliInstalled {
            cliBanner
          }
          if let source = store.context.source {
            sourceSection(source)
          }
          ForEach(store.context.launchRoles) { role in
            launchRoleSection(role)
          }
          ForEach(store.context.pickRoles) { role in
            pickRoleSection(role)
          }
          if !store.context.definition.inputs.isEmpty {
            inputsSection
          }
          if !store.context.skipOptions.isEmpty {
            skipSection
          }
          if store.showsDontAskAgain {
            Toggle("Don't ask again for this workflow", isOn: dontAskAgainBinding)
              .help("Start this workflow without the sheet whenever nothing needs a decision.")
          }
          if let error = store.submissionError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.callout)
              .foregroundStyle(.red)
          }
        }
        .padding(16)
      }
      .frame(maxHeight: 420)
      Divider()
      footer
    }
    .frame(maxWidth: 560)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    .shadow(radius: 32, x: 0, y: 12)
    .padding(16)
    .background {
      // Pull the keyboard away from the terminal once when the sheet appears, so Esc and
      // Return reach the sheet. Unlike the handoff HUD's capture view this never re-grabs:
      // the sheet hosts text fields, and a focused field must keep the keyboard.
      WorkflowStartKeyAnchor(
        onEscape: { store.send(.cancelTapped) },
        onReturn: { store.send(.runTapped) }
      )
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(store.context.item.name)
        .font(.headline)
      Text(store.context.item.workflowDescription ?? "Run this workflow in \(store.context.worktreeName).")
        .font(.subheadline)
        .foregroundStyle(.secondary)
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

  private func sourceSection(_ source: WorkflowStartSource) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if source.isPreselectionFixed,
        let fixed = source.candidates.first(where: { $0.surfaceID == source.preselectedSurfaceID })
      {
        LabeledContent("You (\(source.roleName))", value: paneLabel(fixed))
          .help("This workflow was started from the Active Agents row, so its pane is the source.")
      } else {
        Picker(selection: sourceBinding) {
          ForEach(source.candidates) { candidate in
            Text(paneLabel(candidate)).tag(candidate.surfaceID as UUID?)
          }
        } label: {
          Text("You (\(source.roleName))")
        }
        .help("The pane this workflow runs from — the CLI's [source] argument.")
      }
      if store.selectedSourceIsBareShell, store.sourceRequiresAgent {
        Text("A step messages this role, so the source pane must host a detected agent.")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
    }
  }

  private func launchRoleSection(_ role: WorkflowStartLaunchRole) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Picker(selection: launchBinding(role: role.name)) {
        Text("Choose a profile…").tag(nil as UUID?)
        ForEach(store.state.candidates(for: role)) { candidate in
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
        Text(roleTitle(role.name))
      }
      .help("The Agent Profile launched for the \(role.name) role.")
      if let note = role.rejectedNote {
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
        suggestionConfirmBlock(role)
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

  private func pickRoleSection(_ role: WorkflowStartPickRole) -> some View {
    Picker(selection: pickBinding(role: role.name)) {
      Text("Choose a pane…").tag(nil as UUID?)
      ForEach(role.candidates.filter { $0.surfaceID != store.selectedSourceSurfaceID }) { candidate in
        Text(paneLabel(candidate)).tag(candidate.surfaceID as UUID?)
      }
    } label: {
      Text(roleTitle(role.name))
    }
    .help("An agent already running in this worktree takes the \(role.name) role.")
  }

  private var inputsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(store.context.definition.inputs, id: \.name) { input in
        if !input.values.isEmpty {
          Picker(input.name, selection: inputBinding(name: input.name)) {
            ForEach(input.values, id: \.self) { value in
              Text(value).tag(value)
            }
          }
          .help(input.prompt ?? "The \(input.name) input.")
        } else {
          TextField(input.name, text: inputBinding(name: input.name), prompt: Text(input.prompt ?? input.name))
            .help(input.prompt ?? "The \(input.name) input.")
        }
      }
    }
  }

  private var skipSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(store.context.skipOptions, id: \.stepID) { option in
        let consequence = store.state.skipConsequence(for: option.stepID)
        let endsRun = isEndsRun(consequence)
        VStack(alignment: .leading, spacing: 2) {
          Toggle(
            "Skip \(option.title ?? option.stepID)",
            isOn: skipBinding(stepID: option.stepID)
          )
          .disabled(endsRun && !store.skippedSteps.contains(option.stepID))
          .help("Start the run without this step.")
          if let text = consequenceText(consequence) {
            Text(text)
              .font(.footnote)
              .foregroundStyle(endsRun ? .orange : .secondary)
          }
        }
      }
    }
  }

  private var footer: some View {
    HStack {
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

  private func roleTitle(_ role: String) -> String {
    role.prefix(1).uppercased() + role.dropFirst()
  }

  private func suggestionSummary(_ suggestion: WorkflowProfileSuggestion) -> String {
    var parts: [String] = []
    if let agent = suggestion.agent { parts.append(agent) }
    if let model = suggestion.model { parts.append("model \(model)") }
    if let effort = suggestion.reasoningEffort { parts.append("\(effort) effort") }
    if let mode = suggestion.executionMode { parts.append("\(mode) mode") }
    return "Suggested by the workflow: " + parts.joined(separator: " · ")
  }

  private func isEndsRun(_ consequence: WorkflowSkipConsequence?) -> Bool {
    if case .endsRun = consequence { return true }
    return false
  }

  private func consequenceText(_ consequence: WorkflowSkipConsequence?) -> String? {
    switch consequence {
    case .endsRun(let dependent):
      return "Cannot skip: step '\(dependent)' needs its output."
    case .continues(let optional) where !optional.isEmpty:
      return "The run continues; \(optional.joined(separator: ", ")) proceeds without this output."
    case .continues, .noOutput, nil:
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
    context.launchRoles.contains { $0.effectiveBind == .ask } || dontAskAgain
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
