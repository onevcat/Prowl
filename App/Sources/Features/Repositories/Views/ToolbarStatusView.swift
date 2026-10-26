import ComposableArchitecture
import ProwlCLIShared
import SwiftUI

struct ToolbarStatusView: View {
  @Dependency(FeatureFlags.self) private var featureFlags
  let toast: RepositoriesFeature.StatusToast?
  let githubRateLimit: GithubRateLimitStatus?
  let workflow: WorkflowStatusCenterPresentation
  let pullRequest: GithubPullRequest?
  let codeHost: CodeHost
  var remoteAgentConsent: RemoteAgentConsentPrompt?
  var remoteChannel: RemoteChannelToolbarStatus?
  var remoteFolder: RemoteFolderToolbarStatus?
  let onWorkflowIntent: (WorkflowRunPanelIntent) -> Void
  let onRetryGithubRateLimit: () -> Void
  var onRemoteAgentConsent: (RemoteAgentConsentChoice) -> Void = { _ in }
  var onOpenAgentSettings: () -> Void = {}
  var onRebindRemoteHost: (HostProfile.ID) -> Void = { _ in }

  var body: some View {
    let selection = ToolbarStatusSelection(
      toast: toast,
      workflow: featureFlags.workflowUI
        ? workflow : WorkflowStatusCenterPresentation(state: .init(), selectedWorktreeID: nil, now: .distantPast),
      pullRequest: pullRequest,
      githubRateLimit: githubRateLimit,
      remoteAgentConsent: remoteAgentConsent,
      remoteChannel: remoteChannel,
      remoteFolder: remoteFolder
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
      case .remoteAgentConsent(let prompt):
        RemoteAgentConsentStatusButton(prompt: prompt, onChoice: onRemoteAgentConsent)
          .transition(.opacity)
      case .remoteChannel(let status):
        RemoteChannelStatusButton(status: status, onOpenSettings: onOpenAgentSettings)
          .transition(.opacity)
      case .remoteFolder(let status):
        RemoteFolderStatusButton(status: status) { onRebindRemoteHost(status.hostProfileID) }
          .transition(.opacity)
      case .githubRateLimited(let status):
        GithubRateLimitStatusButton(status: status, onRetry: onRetryGithubRateLimit)
          .transition(.opacity)
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
  case remoteAgentConsent(RemoteAgentConsentPrompt)
  case workflow(WorkflowStatusCenterPresentation)
  case githubRateLimited(GithubRateLimitStatus)
  case remoteChannel(RemoteChannelToolbarStatus)
  case remoteFolder(RemoteFolderToolbarStatus)
  case pullRequest(PullRequestStatusModel)
  case motivational

  var isWorkflow: Bool {
    if case .workflow = self { return true }
    return false
  }

  init(
    toast: RepositoriesFeature.StatusToast?,
    workflow: WorkflowStatusCenterPresentation,
    pullRequest: GithubPullRequest?,
    githubRateLimit: GithubRateLimitStatus? = nil,
    remoteAgentConsent: RemoteAgentConsentPrompt? = nil,
    remoteChannel: RemoteChannelToolbarStatus? = nil,
    remoteFolder: RemoteFolderToolbarStatus? = nil
  ) {
    // The consent question outranks running work: until it is answered, the pane's `ssh`
    // gets no detection (docs-ai 082, L0 item 12).
    if let toast {
      self = .toast(toast)
    } else if let remoteAgentConsent {
      self = .remoteAgentConsent(remoteAgentConsent)
    } else if !workflow.runs.isEmpty {
      self = .workflow(workflow)
    } else if let githubRateLimit {
      self = .githubRateLimited(githubRateLimit)
    } else if let remoteChannel {
      self = .remoteChannel(remoteChannel)
    } else if let remoteFolder, remoteFolder.hostStatus != nil {
      // A folder whose host does not answer as it should, after the focused pane's own
      // channel (docs-ai 084 C1); a connected folder yields to the pull request.
      self = .remoteFolder(remoteFolder)
    } else if let pullRequest = PullRequestStatusModel(pullRequest: pullRequest) {
      self = .pullRequest(pullRequest)
    } else if let remoteFolder {
      self = .remoteFolder(remoteFolder)
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
