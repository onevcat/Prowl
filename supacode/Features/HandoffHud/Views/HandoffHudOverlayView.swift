import AppKit
import ComposableArchitecture
import ProwlCLIShared
import SwiftUI

/// Command-palette-style overlay hosting the hand-off flow (docs-ai 047.004).
/// The panel is a projection of `HandoffHudFeature` state. While *requesting*
/// (waiting for the live agent to run the hand-off) the panel is non-modal:
/// the keyboard stays with the terminal — the source agent may need the user
/// to approve a permission prompt — and clicking outside collapses the panel
/// (the hand-off completes headlessly and notifies). The context-only fallback
/// crosses directly into the non-cancellable finishing stage.
struct HandoffHudOverlayView: View {
  let store: StoreOf<HandoffHudFeature>

  var body: some View {
    ZStack {
      Color.clear
        .contentShape(.rect)
        .onTapGesture {
          switch store.phase {
          case .choosing:
            store.send(.cancelTapped)
          case .finished:
            store.send(.closeTapped)
          case .running(let run) where run.stage == .requesting:
            store.send(.cancelTapped)
          case .running:
            break
          }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Dismiss Hand Off")

      GeometryReader { geometry in
        VStack {
          HandoffHudCard(store: store)
            .zIndex(1)
          Spacer(minLength: 0)
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        .padding(.top, max(0, geometry.size.height * 0.22))
      }
    }
  }
}

private struct HandoffHudCard: View {
  let store: StoreOf<HandoffHudFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      switch store.phase {
      case .choosing:
        HandoffHudChooseView(store: store)
      case .running(let run):
        HandoffHudRunView(
          run: run,
          sourceDisplayName: store.source.displayName,
          onContextOnly: { store.send(.fallbackContextOnlyTapped) },
          onCancel: { store.send(.cancelTapped) }
        )
      case .finished(let outcome):
        HandoffHudFinishedView(outcome: outcome) {
          store.send(.closeTapped)
        }
      }
    }
    .background {
      // Capture keys only while the panel truly owns the interaction
      // (choosing / finished). While requesting, the keyboard must stay with
      // the terminal so the user can approve the source agent's permission
      // prompts; the context-only fallback is button-driven.
      if capturesKeyboard {
        HandoffHudKeyCaptureView(
          onMove: { delta in store.send(.moveSelection(delta: delta)) },
          onConfirm: { confirmForCurrentPhase() },
          onEscape: { escapeForCurrentPhase() }
        )
      }
    }
    .frame(maxWidth: 560)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    .shadow(radius: 32, x: 0, y: 12)
    .padding(16)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(headerTitle)
        .font(.headline)
      Text(headerSubtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var headerTitle: String {
    switch store.phase {
    case .choosing:
      return "Hand Off"
    case .running(let run):
      switch run.target.kind {
      case .agent:
        return "Handing off to \(run.target.title)"
      case .briefOnly:
        return "Saving progress"
      }
    case .finished(.handedOff(let name)):
      return "Handed off to \(name)"
    case .finished(.briefSaved):
      return "Progress saved"
    case .finished(.failed):
      return "Hand off failed"
    }
  }

  private var headerSubtitle: String {
    switch store.phase {
    case .choosing:
      return "Pass this task to another agent in a new tab. "
        + "\(store.source.displayName) writes its own briefing first."
    case .running(let run):
      switch run.stage {
      case .requesting:
        return "Waiting for \(store.source.displayName) to write its briefing and run the hand-off"
      case .finishing:
        return "Finishing the hand-off"
      }
    case .finished(.handedOff):
      return "The receiving agent picks up the task in a new tab"
    case .finished(.briefSaved):
      return "The current state is saved for a later hand-off"
    case .finished(.failed(let message)):
      return message
    }
  }

  private var capturesKeyboard: Bool {
    switch store.phase {
    case .choosing, .finished:
      return true
    case .running:
      return false
    }
  }

  private func confirmForCurrentPhase() {
    switch store.phase {
    case .choosing:
      store.send(.confirmSelection)
    case .finished:
      store.send(.closeTapped)
    case .running:
      break
    }
  }

  private func escapeForCurrentPhase() {
    switch store.phase {
    case .choosing, .running:
      store.send(.cancelTapped)
    case .finished:
      store.send(.closeTapped)
    }
  }
}

// MARK: - Choose step

private struct HandoffHudChooseView: View {
  let store: StoreOf<HandoffHudFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(spacing: 4) {
        ForEach(Array(store.targets.enumerated()), id: \.element.id) { index, target in
          HandoffTargetRow(
            target: target,
            isSelected: index == store.selectedIndex
          ) {
            store.send(.setSelectedIndex(index))
          }
        }
      }
      .padding(12)

      Divider()

      HStack {
        Spacer()
        Button("Cancel") {
          store.send(.cancelTapped)
        }
        .keyboardShortcut(.cancelAction)
        Button(continueTitle) {
          store.send(.confirmSelection)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
  }

  private var continueTitle: String {
    guard store.targets.indices.contains(store.selectedIndex) else { return "Continue" }
    let target = store.targets[store.selectedIndex]
    switch target.kind {
    case .agent:
      return "Hand Off to \(target.title)"
    case .briefOnly:
      return "Save Progress"
    }
  }
}

private struct HandoffTargetRow: View {
  let target: HandoffTargetOption
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(spacing: 10) {
        icon
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(target.title)
              .font(.body)
            if target.isCurrentAgent {
              Text("fresh session")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            }
          }
          Text(target.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
    )
    .help(rowHelp)
  }

  @ViewBuilder
  private var icon: some View {
    switch target.kind {
    case .agent(let agent):
      if let source = CommandIconMap.iconForFirstToken(agent.iconLookupToken) {
        TabIconImage(rawName: source.storageString, pointSize: 18)
      } else {
        Image(systemName: "sparkle")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
    case .briefOnly:
      Image(systemName: "square.and.pencil")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }

  private var rowHelp: String {
    switch target.kind {
    case .agent:
      return "Hand this task to \(target.title) in a new tab"
    case .briefOnly:
      return "Save the agent's progress for a later hand-off without launching anything"
    }
  }
}

// MARK: - Run step

private struct HandoffHudRunView: View {
  let run: HandoffHudRun
  let sourceDisplayName: String
  let onContextOnly: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
        Text(stageDescription)
          .font(.body)
        Spacer(minLength: 0)
      }
      .padding(16)

      Divider()

      HStack {
        Text(footerHint)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if run.stage == .requesting {
          Button("Context Only") {
            onContextOnly()
          }
          .help("Don't wait: hand off with generated context only, no briefing")
        }
        if run.stage != .finishing {
          Button("Cancel") {
            onCancel()
          }
          .keyboardShortcut(.cancelAction)
          .help(cancelHelp)
        }
      }
      .padding(12)
    }
  }

  private var stageDescription: String {
    switch run.stage {
    case .requesting:
      switch run.target.kind {
      case .agent:
        return "Asked \(sourceDisplayName) to write its briefing and hand off to \(run.target.title)"
      case .briefOnly:
        return "Asked \(sourceDisplayName) to write a briefing checkpoint"
      }
    case .finishing:
      return "Finishing the hand-off"
    }
  }

  private var footerHint: String {
    switch run.stage {
    case .requesting:
      return "The request is queued if \(sourceDisplayName) is busy."
    case .finishing:
      return "This hand-off has started and will finish in the background."
    }
  }

  private var cancelHelp: String {
    switch run.stage {
    case .requesting:
      return "Close this panel; if \(sourceDisplayName) still hands off, it completes in the background"
    case .finishing:
      return ""
    }
  }
}

// MARK: - Finished step

private struct HandoffHudFinishedView: View {
  let outcome: HandoffHudOutcome
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        icon
        Text(message)
          .font(.body)
        Spacer(minLength: 0)
      }
      .padding(16)

      Divider()

      HStack {
        Spacer()
        Button("Close") {
          onClose()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
  }

  @ViewBuilder
  private var icon: some View {
    switch outcome {
    case .handedOff, .briefSaved:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(.title2)
        .accessibilityLabel("Success")
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
        .font(.title2)
        .accessibilityLabel("Failure")
    }
  }

  private var message: String {
    switch outcome {
    case .handedOff(let name):
      return "New tab opened with \(name)"
    case .briefSaved:
      return "Hand-off notes are up to date"
    case .failed:
      return "Nothing was launched"
    }
  }
}

// MARK: - Key capture

/// Grabs first-responder status while the HUD is visible so arrow keys,
/// Return, and Escape drive the panel instead of leaking into the focused
/// terminal surface (where they would reach a live agent session).
private struct HandoffHudKeyCaptureView: NSViewRepresentable {
  let onMove: (Int) -> Void
  let onConfirm: () -> Void
  let onEscape: () -> Void

  func makeNSView(context: Context) -> KeyCaptureNSView {
    let view = KeyCaptureNSView()
    view.onMove = onMove
    view.onConfirm = onConfirm
    view.onEscape = onEscape
    return view
  }

  func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
    nsView.onMove = onMove
    nsView.onConfirm = onConfirm
    nsView.onEscape = onEscape
    nsView.grabFocusIfNeeded()
  }

  final class KeyCaptureNSView: NSView {
    var onMove: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      grabFocusIfNeeded()
    }

    func grabFocusIfNeeded() {
      guard let window, window.firstResponder !== self else { return }
      window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
      switch event.keyCode {
      case 126:  // up arrow
        onMove?(-1)
      case 125:  // down arrow
        onMove?(1)
      case 36, 76:  // return, keypad enter
        onConfirm?()
      case 53:  // escape
        onEscape?()
      default:
        // Swallow everything else: keys must never leak into the terminal
        // behind the panel.
        break
      }
    }
  }
}
