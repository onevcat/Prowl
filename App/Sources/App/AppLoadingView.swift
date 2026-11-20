import SwiftUI

struct AppLoadingView: View {
  // Each appearance shows the messages in a new random order, so a launch does not always
  // start with the same message.
  @State private var order = Self.messages.indices.shuffled()
  @State private var position = 0

  private static let messages: [LocalizedStringResource] = [
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
    "Reopening the splits you left behind",
    "Putting your tabs back in order",
    "Herding parallel agents",
    "Rounding up stray processes",
    "Warming up the context window",
    "Compacting yesterday's context",
    "Reminding agents that tests exist",
    "Hiding the force push button",
    "Checking that nobody pushed to main",
    "Reattaching detached HEADs",
    "Cherry-picking the good ideas",
    "Stashing your worries",
    "Rebasing onto good vibes",
    "Resolving merge conflicts diplomatically",
    "Looking for the missing semicolon",
    "Convincing the linter to relax",
    "Negotiating with the type checker",
    "Garbage-collecting excuses",
    "Asking agents to read the docs first",
    "Teaching agents to say \"I don't know\"",
    "Turning it off and on again",
    "Bisecting the slow part",
    "Waiting for CI, as usual",
    "Feeding the cat",
  ]

  var body: some View {
    VStack {
      Text(Self.messages[order[position]])
        .font(.title3)
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
          position = (position + 1) % order.count
        }
      }
    }
  }
}
