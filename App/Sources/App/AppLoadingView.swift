import SwiftUI

struct AppLoadingView: View {
  /// Lines about the workspace the launch restores; the agent lines are shared with the mirror.
  private static let messages: [LocalizedStringResource] =
    [
      "Preparing your worktree",
      "Syncing git state",
      "Indexing branches",
      "Staging your workspace",
      "Orchestrating terminals",
      "Aligning refs",
      "Assembling task graph",
      "Tuning buffers",
      "Hydrating caches",
      "Reopening the splits you left behind",
      "Putting your tabs back in order",
    ] + ProwlLoadingMessages.general

  var body: some View {
    VStack {
      ProwlRotatingMessage(Self.messages)
        .font(.title3)
        .bold()
      ProgressView()
        .controlSize(.large)
    }
  }
}
