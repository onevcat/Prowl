import SwiftUI

struct WorkflowStatusPopoverButton: View {
  let presentation: WorkflowStatusCenterPresentation
  let isToolbarVisible: Bool
  let onIntent: (WorkflowRunPanelIntent) -> Void

  @State private var isPresented = false
  @State private var isPinnedOpen = false
  @State private var isHoveringButton = false
  @State private var isHoveringPopover = false
  @State private var selectedRunID: UUID?
  @State private var closeTask: Task<Void, Never>?

  var body: some View {
    Button {
      togglePresentation()
    } label: {
      if let run = presentation.primary {
        HStack(spacing: 6) {
          statusIcon()
          Text(run.currentStepTitle)
            .lineLimit(1)
          if presentation.activeRunCount > 1 {
            Text(presentation.activeRunCount, format: .number)
              .font(.caption2.monospacedDigit())
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.quaternary, in: Capsule())
              .accessibilityLabel("\(presentation.activeRunCount) active workflow runs")
          }
        }
      }
    }
    .buttonStyle(.plain)
    .font(.caption)
    .contentShape(.rect)
    .help("Workflow status. Hover to preview or click to keep the run panel open.")
    .accessibilityLabel(accessibilityLabel)
    .onHover { hovering in
      isHoveringButton = hovering
      updatePresentation()
    }
    .opacity(isToolbarVisible ? 1 : 0)
    .allowsHitTesting(isToolbarVisible)
    .accessibilityHidden(!isToolbarVisible)
    .popover(isPresented: $isPresented) {
      WorkflowRunPanelView(
        presentation: presentation,
        selectedRunID: $selectedRunID,
        onInteraction: pinPresentation,
        onIntent: onIntent
      )
      .onHover { hovering in
        isHoveringPopover = hovering
        updatePresentation()
      }
      .onDisappear {
        isHoveringPopover = false
        isPinnedOpen = false
        selectedRunID = nil
      }
    }
    .onChange(of: presentation.runs.map(\.id)) { _, runIDs in
      guard !runIDs.isEmpty else {
        closePopover()
        return
      }
      if selectedRunID.map({ !runIDs.contains($0) }) == true {
        selectedRunID = defaultRunID
      }
    }
    .onChange(of: isToolbarVisible) { _, visible in
      if !visible, !isPinnedOpen {
        isHoveringButton = false
        updatePresentation()
      }
    }
    .onDisappear {
      closeTask?.cancel()
    }
  }

  @ViewBuilder
  private func statusIcon() -> some View {
    if presentation.hasAttention {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
    } else {
      ProgressView()
        .controlSize(.small)
        .accessibilityHidden(true)
    }
  }

  private var accessibilityLabel: String {
    guard let run = presentation.attentionRun ?? presentation.primary else { return "Workflow status" }
    let prefix = presentation.hasAttention ? "Workflow needs attention" : "Workflow running"
    let count = presentation.activeRunCount > 1 ? ", \(presentation.activeRunCount) active runs" : ""
    return "\(prefix): \(run.currentStepTitle)\(count)"
  }

  private func togglePresentation() {
    if isPinnedOpen {
      closePopover()
      return
    }
    closeTask?.cancel()
    selectedRunID = selectedRunID ?? defaultRunID
    pinPresentation()
  }

  private func pinPresentation() {
    closeTask?.cancel()
    isPinnedOpen = true
    isPresented = true
  }

  private func updatePresentation() {
    if isPinnedOpen || isHoveringButton || isHoveringPopover {
      closeTask?.cancel()
      selectedRunID = selectedRunID ?? defaultRunID
      isPresented = true
      return
    }
    closeTask?.cancel()
    closeTask = Task { @MainActor in
      try? await ContinuousClock().sleep(for: .milliseconds(150))
      if !Task.isCancelled {
        isPresented = false
      }
    }
  }

  private func closePopover() {
    closeTask?.cancel()
    isPinnedOpen = false
    isPresented = false
  }

  private var defaultRunID: UUID? {
    presentation.attentionRun?.id ?? presentation.primary?.id
  }
}

private struct WorkflowRunPanelView: View {
  let presentation: WorkflowStatusCenterPresentation
  @Binding var selectedRunID: UUID?
  let onInteraction: () -> Void
  let onIntent: (WorkflowRunPanelIntent) -> Void

  @State private var pendingConfirmation: PendingConfirmation?
  @State private var isConfirming = false

  var body: some View {
    HStack(spacing: 0) {
      if presentation.runs.count > 1 {
        runList
        Divider()
      }
      if let run = selectedRun {
        runDetail(run)
      }
    }
    .frame(
      width: presentation.runs.count > 1 ? 760 : 580,
      height: 600
    )
    .onAppear {
      selectFirstRunIfNeeded()
    }
    .onChange(of: presentation.runs.map(\.id)) { _, _ in
      selectFirstRunIfNeeded()
    }
    .confirmationDialog(
      "Confirm Workflow Action",
      isPresented: $isConfirming,
      presenting: pendingConfirmation
    ) { pending in
      Button(pending.label, role: pending.isDestructive ? .destructive : nil) {
        onIntent(pending.intent)
        pendingConfirmation = nil
      }
      Button("Cancel", role: .cancel) {
        pendingConfirmation = nil
      }
    } message: { pending in
      Text(pending.message)
    }
  }

  private var selectedRun: WorkflowRunPresentation? {
    presentation.runs.first { $0.id == selectedRunID } ?? presentation.primary
  }

  private var runList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 4) {
        Text("Active Runs")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.bottom, 2)
        ForEach(presentation.runs) { run in
          Button {
            onInteraction()
            selectedRunID = run.id
          } label: {
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: run.status.isAttention ? "exclamationmark.triangle.fill" : run.workflowIcon)
                .foregroundStyle(run.status.isAttention ? .orange : .secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 2) {
                Text(run.workflowName)
                  .lineLimit(1)
                Text(run.currentStepTitle)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(.rect)
            .background(
              run.id == selectedRunID ? Color.accentColor.opacity(0.12) : Color.clear,
              in: RoundedRectangle(cornerRadius: 6)
            )
          }
          .buttonStyle(.plain)
          .help("Show \(run.workflowName)")
        }
      }
      .padding(8)
    }
    .frame(width: 190)
  }

  private func runDetail(_ run: WorkflowRunPresentation) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      runHeader(run)
      roleRow(run)
      Divider()
      stepList(run)
        .frame(maxHeight: .infinity)
      if case .needsAttention(let message) = run.status {
        attentionBlock(run, message: message)
      }
      Divider()
      footer(run)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func runHeader(_ run: WorkflowRunPresentation) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: run.workflowIcon)
        .font(.title3)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(run.workflowName)
          .font(.headline)
        TimelineView(.periodic(from: .now, by: 30)) { context in
          Text("\(run.worktreeName) · \(run.elapsedText(at: context.date)) · \(run.status.label)")
            .font(.subheadline)
            .foregroundStyle(run.status.isAttention ? .orange : .secondary)
        }
      }
      Spacer(minLength: 0)
      if presentation.runs.count > 1 {
        Text("\(presentation.activeRunCount) active")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func roleRow(_ run: WorkflowRunPresentation) -> some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        ForEach(run.roles) { role in
          Button {
            onInteraction()
            guard let surfaceID = role.surfaceID else { return }
            onIntent(.focusPane(worktreeID: run.worktreeID, surfaceID: surfaceID))
          } label: {
            HStack(spacing: 5) {
              TabIconImage(
                rawName: (role.agent.flatMap(CommandIconMap.iconForFirstToken)
                  ?? TabIconSource(systemSymbol: "sparkles")).storageString,
                pointSize: 11
              )
              Text(role.displayName)
                .lineLimit(1)
              if let paneHandle = role.paneHandle {
                Text(paneHandle)
                  .monospaced()
                  .foregroundStyle(.secondary)
              }
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(role.surfaceID == nil)
          .help(
            role.surfaceID == nil
              ? "\(role.displayName) has no pane yet"
              : "Focus \(role.displayName) in \(role.paneHandle ?? "its pane")"
          )
        }
      }
    }
    .scrollIndicators(.never)
  }

  private func stepList(_ run: WorkflowRunPresentation) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 8) {
        ForEach(run.stepItems) { item in
          switch item {
          case .step(let step):
            stepRow(step, currentInstruction: run.currentInstruction)
          case .round(let round):
            VStack(alignment: .leading, spacing: 6) {
              Text(round.maximum.map { "Round \(round.index) / \($0)" } ?? "Round \(round.index)")
                .font(.caption)
                .foregroundStyle(.secondary)
              ForEach(round.steps) { step in
                stepRow(step, currentInstruction: run.currentInstruction)
              }
            }
            .padding(.top, 4)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityLabel("Workflow steps")
  }

  private func stepRow(
    _ step: WorkflowStepPresentation,
    currentInstruction: String?
  ) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: step.state.symbol)
        .foregroundStyle(step.state.color)
        .frame(width: 14)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(step.title)
          .foregroundStyle(step.state == .pending ? .secondary : .primary)
        if step.state == .active, let currentInstruction {
          Text(currentInstruction)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
    .font(.subheadline)
    .accessibilityElement(children: .combine)
  }

  private func attentionBlock(
    _ run: WorkflowRunPresentation,
    message: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        Text(message)
          .font(.subheadline)
          .fixedSize(horizontal: false, vertical: true)
      }
      controlLayout(run.attentionControls.filter { $0.action != .cancel }, run: run)
    }
    .padding(10)
    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Workflow needs attention")
  }

  @ViewBuilder
  private func controlLayout(
    _ controls: [WorkflowAttentionControl],
    run: WorkflowRunPresentation
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        ForEach(controls) { control in
          controlView(control, run: run)
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        ForEach(controls) { control in
          controlView(control, run: run)
        }
      }
    }
  }

  @ViewBuilder
  private func controlView(
    _ control: WorkflowAttentionControl,
    run: WorkflowRunPresentation
  ) -> some View {
    if control.action == .acceptWithVerdict {
      Menu {
        ForEach(control.verdicts, id: \.self) { verdict in
          Button(verdict) {
            perform(control, run: run, verdict: verdict)
          }
        }
      } label: {
        Label(control.label, systemImage: control.systemImage)
      }
      .onHover { hovering in
        if hovering { onInteraction() }
      }
      .help("Accept the delivery with a declared verdict")
    } else {
      Button {
        perform(control, run: run)
      } label: {
        Label(control.label, systemImage: control.systemImage)
      }
      .disabled(control.intent(runID: run.id, worktreeID: run.worktreeID) == nil)
      .help(control.label)
    }
  }

  private func footer(_ run: WorkflowRunPresentation) -> some View {
    HStack(spacing: 10) {
      Button("Reveal Run Folder", systemImage: "folder") {
        onInteraction()
        onIntent(.revealRunFolder(run.runDirectory))
      }
      .help("Reveal this workflow run in Finder")
      Button("Open Log", systemImage: "doc.text") {
        onInteraction()
        onIntent(.openLog(run.logURL))
      }
      .help("Open this workflow run's log")
      Spacer(minLength: 0)
      Button("Cancel Run", role: .destructive) {
        onInteraction()
        requestConfirmation(
          intent: .userAction(runID: run.id, action: .cancel),
          label: "Cancel Run",
          message: "Cancel this workflow run? Its panes and deliveries will be kept.",
          isDestructive: true
        )
      }
      .help("Cancel the workflow and keep its panes and deliveries")
    }
    .controlSize(.small)
  }

  private func perform(
    _ control: WorkflowAttentionControl,
    run: WorkflowRunPresentation,
    verdict: String? = nil
  ) {
    onInteraction()
    guard
      let intent = control.intent(
        runID: run.id,
        worktreeID: run.worktreeID,
        verdict: verdict
      )
    else { return }
    if let message = control.confirmationMessage {
      requestConfirmation(
        intent: intent,
        label: control.label,
        message: message,
        isDestructive: control.isDestructive
      )
    } else {
      onIntent(intent)
    }
  }

  private func requestConfirmation(
    intent: WorkflowRunPanelIntent,
    label: String,
    message: String,
    isDestructive: Bool
  ) {
    pendingConfirmation = PendingConfirmation(
      intent: intent,
      label: label,
      message: message,
      isDestructive: isDestructive
    )
    isConfirming = true
  }

  private func selectFirstRunIfNeeded() {
    let ids = presentation.runs.map(\.id)
    if selectedRunID == nil || selectedRunID.map({ !ids.contains($0) }) == true {
      selectedRunID = presentation.attentionRun?.id ?? ids.first
    }
  }

  private struct PendingConfirmation: Identifiable {
    let id = UUID()
    let intent: WorkflowRunPanelIntent
    let label: String
    let message: String
    let isDestructive: Bool
  }
}

extension WorkflowRunPresentation.Status {
  fileprivate var label: String {
    isAttention ? "Needs Attention" : "Running"
  }
}

extension WorkflowStepPresentation.State {
  fileprivate var symbol: String {
    switch self {
    case .pending: "circle"
    case .active: "play.circle.fill"
    case .completed: "checkmark.circle.fill"
    case .skipped: "forward.end.circle"
    case .failed: "exclamationmark.circle.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .pending: .secondary
    case .active: .accentColor
    case .completed: .green
    case .skipped: .secondary
    case .failed: .orange
    }
  }
}
