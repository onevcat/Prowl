import SwiftUI

struct AppLoadingView: View {
  @State private var messageIndex = 0

  private static let messages = [
    "Preparing your worktree",
    "Getting your agents ready",
    "Syncing git state",
    "Indexing branches",
    "Staging your workspace",
    "Orchestrating terminals",
    "Spinning up runners",
    "Warming up shells",
    "Aligning refs",
    "Assembling task graph",
    "Tuning buffers",
    "Hydrating caches",
    "Removing \"you're absolutely right!\"",
    "Evicting polite overcommit",
    "Reducing agent flattery",
    "Sharpening code opinions",
    "Making the bots decisive",
    "Debouncing Claude Code pleasantries",
    "Calibrating Codex confidence",
    "Pruning Claude Code hedges",
    "Clearing Codex verbosity",
  ]

  var body: some View {
    VStack {
      Text(Self.messages[messageIndex])
        .interfaceFont(.title3)
        .bold()
      ProgressView()
        .controlSize(.large)
    }
    .task {
      await cycleMessages()
    }
  }

  private func cycleMessages() async {
    while !Task.isCancelled {
      try? await ContinuousClock().sleep(for: .seconds(1.8))
      await MainActor.run {
        withAnimation(.easeInOut(duration: 0.25)) {
          messageIndex = (messageIndex + 1) % Self.messages.count
        }
      }
    }
  }
}
