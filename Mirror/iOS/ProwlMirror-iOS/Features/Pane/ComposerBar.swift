import SwiftUI

/// One composer for both views (docs-ai 089 S2): a floating glass field with the send button
/// inside. Send goes through `agents.input`. A note appears only when the Host will do
/// something other than deliver now, and a receipt never locks the field without a way out.
/// A message in flight only turns Send into a spinner: it takes a moment, and a note or the
/// receipt controls would push the chat up and back for each message.
struct ComposerBar: View {
  @Bindable var session: MirrorSession
  @Binding var isEditing: Bool
  @State private var confirmsStop = false

  /// While the agent works and nothing is typed, the button stops it instead (docs-ai 089 S5).
  private var showsStop: Bool {
    session.canStopAgent && session.draft.isEmpty
  }
  private var isSending: Bool { session.submission?.outcome.status == .pending }
  /// The measured width of the trailing buttons; Send and Stop grow with Dynamic Type up to a
  /// limit, so a constant reservation overlaps the text at accessibility sizes.
  @State private var controlsWidth: CGFloat = 34

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let hostDraft = session.hostDraft {
        hostDraftCard(hostDraft)
          .padding(.horizontal, 12).padding(.vertical, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          // A container, so the card's identifier does not replace its children's.
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("composer-draft-card")
      } else if let note {
        // On glass, like the field: the chat scrolls behind this area, and bare text over it
        // reads as overlapping rows.
        Text(note.text)
          .font(.caption)
          .foregroundStyle(note.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
          .lineLimit(3)
          .padding(.horizontal, 12).padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .accessibilityIdentifier("composer-note")
      }
      if session.submission?.outcome.status == .unknown {
        receiptControls
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
      // The text view sits directly in the VStack so it is proposed a definite width; a
      // UITextView in an HStack gets a nil width during measurement and never grows.
      MirrorComposer(session: session, isEditing: $isEditing)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 6)
        // Room for Send or Stop, so neither covers text.
        .padding(.trailing, controlsWidth + 6)
        .overlay(alignment: .topLeading) {
          if session.draft.isEmpty {
            Text(placeholder).foregroundStyle(.tertiary)
              .padding(.leading, 11).padding(.vertical, 8).allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
        .overlay(alignment: .bottomTrailing) {
          HStack(spacing: 6) {
            if showsStop {
              Button {
                confirmsStop = true
              } label: {
                Image(systemName: "stop.fill")
                  .font(.footnote.weight(.bold))
                  .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                  .foregroundStyle(.white)
                  .frame(width: 32, height: 32)
                  .background(Color.red, in: Circle())
              }
              .accessibilityLabel("Stop")
              .accessibilityIdentifier("mirror-stop")
              .help("Interrupt the agent on the Mac (Escape)")
            } else {
              Button {
                session.submitDraft()
              } label: {
                Group {
                  if isSending {
                    ProgressView().tint(.white).controlSize(.small)
                  } else {
                    Image(systemName: "arrow.up")
                      .font(.body.weight(.bold))
                      // The circle is a fixed 32 points; a larger glyph spills out of it.
                      .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                  }
                }
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                  session.canSubmit || isSending ? Color.accentColor : Color(.systemGray3), in: Circle())
              }
              .disabled(!session.canSubmit)
              .accessibilityLabel(isSending ? "Sending" : "Send")
              .accessibilityIdentifier("mirror-send")
              .help("Send the message to the agent on the Host")
            }
          }
          .padding(.trailing, 2)
          .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controlsWidth = $0 }
        }
        .padding(6)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    .animation(.snappy, value: note)
    .animation(.snappy, value: session.hostDraft)
    .animation(.snappy, value: showsStop)
    .animation(.snappy, value: isSending)
    .confirmationDialog("Stop the agent?", isPresented: $confirmsStop, titleVisibility: .visible) {
      Button("Stop", role: .destructive) { session.sendKeys(["esc"]) }
        .accessibilityIdentifier("mirror-stop-confirm")
    } message: {
      Text("Prowl presses Escape in the pane on the Mac, which interrupts the current turn.")
    }
  }

  /// The Mac's input box holds a draft, so the message was not sent: the person decides on the
  /// phone (docs-ai 090). Replace clears it there first (Claude Code stashes it and brings it back
  /// after the message is sent); Bring Here puts its text in front of this message to merge them.
  private func hostDraftCard(_ hostDraft: MirrorHostDraft) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("The input box on the Mac still holds a draft, so your message was not sent:")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(hostDraft.excerpt)
        .font(.caption.monospaced())
        .lineLimit(3)
        .textSelection(.enabled)
        .accessibilityIdentifier("composer-draft-text")
      if !hostDraft.isComplete {
        Text(
          "The screen does not show it exactly (several lines, an attachment, or a collapsed paste), so it cannot be brought here."
        )
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        if hostDraft.replaceable {
          Button("Replace and Send") { session.replaceHostDraftAndSend() }
            .buttonStyle(.borderedProminent)
            .disabled(!session.canSubmit)
            .accessibilityIdentifier("mirror-replace-draft")
            .help(
              hostDraft.recovery == "stash"
                ? "Set the draft aside on the Mac, send your message, and let the Mac bring the draft back"
                : "Clear the draft on the Mac and send your message")
        }
        Button("Bring Draft Here") { session.bringHostDraftHere() }
          .disabled(!hostDraft.isComplete)
          .accessibilityIdentifier("mirror-bring-draft")
          .help("Put the Mac's draft in front of your message so you can merge them; sending then replaces it on the Mac")
        Button("Cancel") { session.dismissHostDraft() }
          .accessibilityIdentifier("mirror-dismiss-draft")
          .help("Keep your message here and leave the draft on the Mac")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  private var receiptControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button("Check Receipt") { session.querySubmission() }
          .disabled(session.status != .live)
        if session.submission?.outcome.status == .unknown {
          Button("I've Checked") { session.acknowledgeUnknownSubmission() }
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      if let submission = session.submission {
        DisclosureGroup("Submitted message") {
          ScrollView { Text(submission.text).textSelection(.enabled) }.frame(maxHeight: 120)
        }
        .font(.caption)
      }
    }
    .padding(.horizontal, 6)
  }

  private var placeholder: String {
    if session.pane?.agent != nil { return String(localized: "Message") }
    return session.supportsShellSend ? String(localized: "Command") : String(localized: "Terminal is read-only here")
  }

  private struct Note: Equatable {
    let text: String
    let isProblem: Bool
  }

  /// Only what changes the outcome: a receipt that is refused or unconfirmed, a refused key, or a
  /// pane that does not take messages. A working agent takes a message as typed on the Mac: it
  /// queues or steers it by its own rules (docs-ai 089 S6), so that needs no note.
  private var note: Note? {
    if let submission = session.submission, submission.outcome.status != .accepted,
      submission.outcome.status != .pending
    {
      let problem = submission.outcome.status == .rejected || submission.outcome.status == .unknown
      return Note(text: submission.outcome.detail, isProblem: problem)
    }
    // A message that replaced a draft on the Mac says where that draft went, until the next one.
    if let submission = session.submission, submission.outcome.status == .accepted,
      submission.outcome.replacedDraft != nil, session.draft.isEmpty
    {
      return Note(text: submission.outcome.detail, isProblem: false)
    }
    guard session.status == .live else { return nil }
    if let refusal = session.keyRefusal { return Note(text: refusal, isProblem: true) }
    if !session.supportsSubmission {
      return Note(text: String(localized: "This Host does not accept messages for this pane."), isProblem: false)
    }
    return nil
  }
}
