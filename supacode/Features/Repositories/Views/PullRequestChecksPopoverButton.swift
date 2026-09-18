import SwiftUI

struct PullRequestChecksPopoverButton<Label: View>: View {
  let pullRequest: GithubPullRequest
  @ViewBuilder let label: () -> Label
  @State private var isPresented = false
  @State private var isHoveringButton = false
  @State private var isHoveringPopover = false
  @State private var closeTask: Task<Void, Never>?
  @Environment(\.openURL) private var openURL
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings

  var body: some View {
    let pullRequestURL = URL(string: pullRequest.url)
    let checks = pullRequest.statusCheckRollup?.checks ?? []
    Button {
      if let pullRequestURL {
        openURL(pullRequestURL)
      }
    } label: {
      label()
    }
    .buttonStyle(.plain)
    .contentShape(.rect)
    .help(openPullRequestHelpText)
    .accessibilityLabel("Open pull request on GitHub")
    .onHover { hovering in
      isHoveringButton = hovering
      updatePresentation()
    }
    .popover(isPresented: $isPresented) {
      PullRequestChecksPopoverView(
        pullRequest: pullRequest,
        checks: checks
      )
      .onHover { hovering in
        isHoveringPopover = hovering
        updatePresentation()
      }
      .onDisappear {
        isHoveringPopover = false
        updatePresentation()
      }
    }
    .onDisappear {
      closeTask?.cancel()
    }
  }

  private func updatePresentation() {
    if isHoveringButton || isHoveringPopover {
      closeTask?.cancel()
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

  private var openPullRequestShortcut: AppShortcut? {
    AppShortcuts.resolvedShortcut(
      for: AppShortcuts.CommandID.openPullRequest,
      in: resolvedKeybindings
    )
  }

  private var openPullRequestHelpText: String {
    if let display = openPullRequestShortcut?.display {
      return String(localized: "Open pull request on GitHub (\(display)). Hover to show checks.")
    }
    return String(localized: "Open pull request on GitHub. Hover to show checks.")
  }
}
