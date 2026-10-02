import ComposableArchitecture
import ProwlCLIShared
import SwiftUI

struct ToolbarStatusView: View {
  @Dependency(FeatureFlags.self) private var featureFlags
  let toast: RepositoriesFeature.StatusToast?
  let workflow: WorkflowStatusCenterPresentation
  let pullRequest: GithubPullRequest?
  let codeHost: CodeHost
  let onWorkflowIntent: (WorkflowRunPanelIntent) -> Void

  var body: some View {
    let selection = ToolbarStatusSelection(
      toast: toast,
      workflow: featureFlags.workflowUI
        ? workflow : WorkflowStatusCenterPresentation(state: .init(), selectedWorktreeID: nil, now: .distantPast),
      pullRequest: pullRequest
    )
    ZStack {
      // Keep the panel mounted so a selected run remains readable after the last active run ends.
      if featureFlags.workflowUI {
        WorkflowStatusPopoverButton(
          presentation: workflow,
          isToolbarVisible: selection.isWorkflow,
          onIntent: onWorkflowIntent
        )
      }
      switch selection {
      case .toast(.inProgress(let message)):
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
      case .toast(.success(let message)):
        HStack(spacing: 6) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .accessibilityHidden(true)
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
      case .toast(.warning(let message)):
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
      case .workflow:
        EmptyView()
      case .pullRequest(let model):
        PullRequestStatusButton(model: model, codeHost: codeHost)
          .transition(.opacity)
      case .motivational:
        MotivationalStatusView()
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: toast)
    .animation(.easeInOut(duration: 0.2), value: workflow.runs.map(\.id))
  }
}

@MainActor
enum ToolbarStatusSelection: Equatable {
  case toast(RepositoriesFeature.StatusToast)
  case workflow(WorkflowStatusCenterPresentation)
  case pullRequest(PullRequestStatusModel)
  case motivational

  var isWorkflow: Bool {
    if case .workflow = self { return true }
    return false
  }

  init(
    toast: RepositoriesFeature.StatusToast?,
    workflow: WorkflowStatusCenterPresentation,
    pullRequest: GithubPullRequest?
  ) {
    if let toast {
      self = .toast(toast)
    } else if !workflow.runs.isEmpty {
      self = .workflow(workflow)
    } else if let pullRequest = PullRequestStatusModel(pullRequest: pullRequest) {
      self = .pullRequest(pullRequest)
    } else {
      self = .motivational
    }
  }
}

private struct MotivationalStatusView: View {
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings

  var body: some View {
    TimelineView(.everyMinute) { context in
      let hour = Calendar.current.component(.hour, from: context.date)
      let style = timeStyle(for: hour)
      let commandPaletteHint = AppShortcuts.helpText(
        title: "Open Command Palette",
        commandID: AppShortcuts.CommandID.commandPalette,
        in: resolvedKeybindings
      )
      HStack(spacing: 8) {
        Image(systemName: style.icon)
          .foregroundStyle(style.color)
          .font(.callout)
          .accessibilityHidden(true)
        Text("\(context.date, format: .dateTime.hour().minute()) – \(commandPaletteHint)")
          .font(.footnote)
          .monospaced()
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct TimeStyle {
  let icon: String
  let color: Color
}

private func timeStyle(for hour: Int) -> TimeStyle {
  switch hour {
  case 6..<12:
    TimeStyle(icon: "sunrise.fill", color: .orange)
  case 12..<17:
    TimeStyle(icon: "sun.max.fill", color: .yellow)
  case 17..<21:
    TimeStyle(icon: "sunset.fill", color: .pink)
  default:
    TimeStyle(icon: "moon.stars.fill", color: .indigo)
  }
}
