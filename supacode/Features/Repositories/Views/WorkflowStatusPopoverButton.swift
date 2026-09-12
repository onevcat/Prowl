import ComposableArchitecture
import SwiftUI

struct WorkflowStatusPopoverButton: View {
  @Environment(StoreOf<WorkflowStepHistoryFeature>.self) private var historyStore
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
          statusIcon(run)
          Text(run.summaryText)
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
      WorkflowStepHistoryView(store: historyStore, onIntent: onIntent, onInteraction: pinPresentation)
        .onAppear {
          historyStore.send(.setPresented(true))
          if let id = defaultRunID { historyStore.send(.select(id)) }
        }
        .onHover { hovering in
          isHoveringPopover = hovering
          updatePresentation()
        }
        .onDisappear {
          isHoveringPopover = false
          isPinnedOpen = false
          selectedRunID = nil
          historyStore.send(.setPresented(false))
        }
    }
    .onChange(of: presentation.runs.map(\.id)) { _, runIDs in
      guard !runIDs.isEmpty else { return }
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
  private func statusIcon(_ run: WorkflowRunPresentation) -> some View {
    if presentation.hasAttention {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
    } else if case .finished(let outcome) = run.status {
      switch outcome {
      case .completed:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .accessibilityHidden(true)
      case .cancelled, .interrupted:
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      case .skipped, .iterationLimitReached:
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
      }
    } else {
      ProgressView()
        .controlSize(.small)
        .accessibilityHidden(true)
    }
  }

  private var accessibilityLabel: String {
    guard let run = presentation.attentionRun ?? presentation.primary else { return "Workflow status" }
    let count = presentation.activeRunCount > 1 ? ", \(presentation.activeRunCount) active runs" : ""
    if presentation.hasAttention { return "Workflow needs attention: \(run.currentStepTitle)\(count)" }
    if run.status.isFinished { return "Workflow finished: \(run.summaryText)\(count)" }
    return "Workflow running: \(run.currentStepTitle)\(count)"
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
