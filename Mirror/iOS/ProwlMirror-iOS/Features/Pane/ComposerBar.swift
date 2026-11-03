import SwiftUI

/// One composer for both views: Send goes through `agents.input`; the hint says what the
/// Host will do with it, and a receipt never locks the composer without a way out.
struct ComposerBar: View {
  @Bindable var session: MirrorSession
  @Binding var isEditing: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // The text view sits directly in the VStack so it is proposed a definite width; a
      // UITextView in an HStack gets a nil width during measurement and never grows.
      MirrorComposer(session: session, isEditing: $isEditing)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, 40)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .topLeading) {
          if session.draft.isEmpty {
            Text(placeholder).foregroundStyle(.secondary)
              .padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
        .overlay(alignment: .bottomTrailing) {
          Button {
            session.submitDraft()
          } label: {
            Image(systemName: "arrow.up.circle.fill").font(.title2)
          }
          .disabled(!session.canSubmit)
          .padding(.trailing, 6).padding(.bottom, 4)
          .accessibilityLabel("Send")
          .accessibilityIdentifier("mirror-send")
          .help("Send the message to the agent on the Host")
        }
      HStack {
        Text(hint).font(.caption).foregroundStyle(hintColor).lineLimit(2)
        Spacer()
        if isEditing {
          Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") { isEditing = false }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("mirror-dismiss-keyboard")
        }
        if session.submission?.outcome.status == .unknown || session.submission?.outcome.status == .pending {
          Button("Check Receipt") { session.querySubmission() }
            .disabled(session.status != .live)
            .font(.caption)
        }
        if session.submission?.outcome.status == .unknown {
          Button("I've Checked") { session.acknowledgeUnknownSubmission() }.font(.caption)
        }
      }
      if let submission = session.submission,
        submission.outcome.status == .pending || submission.outcome.status == .unknown
      {
        DisclosureGroup("Submitted message") {
          ScrollView { Text(submission.text).textSelection(.enabled) }.frame(maxHeight: 120)
        }
        .font(.caption)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
  }

  private var placeholder: String {
    session.mode == .conversation ? String(localized: "Message the agent") : String(localized: "Write a message")
  }

  private var hint: String {
    if let submission = session.submission, submission.outcome.status != .accepted {
      return submission.outcome.detail
    }
    if session.status != .live { return String(localized: "Reconnect to the pane before sending.") }
    if !session.supportsSubmission { return String(localized: "This Host does not accept messages for this pane.") }
    if session.pane?.agent == nil { return String(localized: "Shell panes are read-only from here.") }
    switch session.agentState {
    case .working: return String(localized: "The agent is working; the Host delivers once its composer is free.")
    case .blocked: return String(localized: "The agent is waiting for an answer on the Mac.")
    default: return String(localized: "Sends to the agent on the Host; it checks readiness first.")
    }
  }

  private var hintColor: Color {
    if let status = session.submission?.outcome.status, status == .rejected || status == .unknown { return .red }
    return .secondary
  }
}
