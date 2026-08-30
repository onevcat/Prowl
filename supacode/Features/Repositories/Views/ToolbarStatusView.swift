import SwiftUI

struct ToolbarStatusView: View {
  let toast: RepositoriesFeature.StatusToast?
  let pullRequest: GithubPullRequest?
  let codeHost: CodeHost

  var body: some View {
    Group {
      switch toast {
      case .inProgress(let message):
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text(message)
            .interfaceFont(.footnote)
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
      case .success(let message):
        HStack(spacing: 6) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .accessibilityHidden(true)
          Text(message)
            .interfaceFont(.footnote)
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
      case .warning(let message):
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          Text(message)
            .interfaceFont(.footnote)
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
      case nil:
        if let model = PullRequestStatusModel(pullRequest: pullRequest) {
          PullRequestStatusButton(model: model, codeHost: codeHost)
            .transition(.opacity)
        } else {
          MotivationalStatusView()
            .transition(.opacity)
        }
      }
    }
    .animation(.easeInOut(duration: 0.2), value: toast)
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
          .interfaceFont(.callout)
          .accessibilityHidden(true)
        Text("\(context.date, format: .dateTime.hour().minute()) – \(commandPaletteHint)")
          .interfaceFont(.footnote, design: .monospaced)
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
