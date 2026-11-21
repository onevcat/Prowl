import SwiftUI

/// Playful lines for a wait: the Mac app's launch screen and the chat of a new mirror session.
enum ProwlLoadingMessages {
  /// Lines about agents and everyday development, which fit any wait.
  static let general: [LocalizedStringResource] = [
    "Getting your agents ready",
    "Spinning up runners",
    "Warming up shells",
    "Removing \"you're absolutely right!\"",
    "Evicting polite overcommit",
    "Reducing agent flattery",
    "Sharpening code opinions",
    "Making the bots decisive",
    "Debouncing Claude Code pleasantries",
    "Calibrating Codex confidence",
    "Pruning Claude Code hedges",
    "Clearing Codex verbosity",
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
}

/// Shows `messages` one at a time, in a new random order on each appearance, so a wait does not
/// always start with the same line.
struct ProwlRotatingMessage: View {
  private let messages: [LocalizedStringResource]
  @State private var order: [Int]
  @State private var position = 0

  init(_ messages: [LocalizedStringResource]) {
    self.messages = messages
    _order = State(initialValue: messages.indices.shuffled())
  }

  var body: some View {
    Text(messages[order[position]])
      .task { await cycle() }
  }

  private func cycle() async {
    let clock = ContinuousClock()
    while !Task.isCancelled {
      do { try await clock.sleep(for: .seconds(1.8)) } catch { return }
      withAnimation(.easeInOut(duration: 0.25)) {
        position = (position + 1) % order.count
      }
    }
  }
}
