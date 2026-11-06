import SwiftUI

/// The question the agent waits on, above the composer (docs-ai 089 S4): what it asks, what it
/// asks about, and its answers as buttons. The Host checks the Mac's screen before it presses
/// anything, so a stale tap is refused instead of answering something else.
struct MirrorPromptPanel: View {
  let prompt: MirrorConversationEvent.Prompt
  let answer: MirrorSession.PromptAnswer?
  /// Sends a choice id; `toggles` is true for a box of a multi-select menu.
  let respond: (_ choice: String, _ toggles: Bool) -> Void

  private var isMultiSelect: Bool { prompt.multiSelect == true }

  private var sentChoice: String? {
    guard let answer, answer.promptID == prompt.id else { return nil }
    switch answer.state {
    case .sending, .delivered: return answer.choice
    case .refused: return nil
    }
  }

  /// No more taps: an answer is on its way, or the menu has been answered. A multi-select menu
  /// takes more boxes until its Submit goes.
  private var isLocked: Bool {
    guard let answer, answer.promptID == prompt.id else { return false }
    switch answer.state {
    case .sending: return true
    case .delivered: return !answer.toggles
    case .refused: return false
    }
  }

  private var refusal: String? {
    guard let answer, answer.promptID == prompt.id, case .refused(let message) = answer.state else { return nil }
    return message
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(kindTitle, systemImage: prompt.kind == .permission ? "lock.shield" : "questionmark.bubble")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.red)
      if let title = prompt.title {
        Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
      }
      if let detail = prompt.detail?.text, !detail.isEmpty {
        Text(detail)
          .font(.footnote.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .padding(.horizontal, 10).padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      VStack(spacing: 6) {
        ForEach(prompt.choices ?? [], id: \.id) { choice in
          choiceButton(choice)
        }
        if isMultiSelect { submitButton }
      }
      if let refusal {
        MirrorFailureLabel(text: refusal).font(.footnote).accessibilityIdentifier("prompt-refusal")
      } else if answer?.state == .delivered, isLocked {
        Label("Sent to the Mac", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
      } else if prompt.freeform {
        Text("To type your own answer, use the Mac.").font(.footnote).foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
    )
    .animation(.snappy, value: answer)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("prompt-panel")
  }

  private func choiceButton(_ choice: MirrorConversationEvent.Choice) -> some View {
    // A box shows what the Mac shows; only a single answer is marked as the one sent.
    let isSent = sentChoice == choice.id && !isMultiSelect
    let isSending = sentChoice == choice.id && answer?.state == .sending
    return Button {
      respond(choice.id, isMultiSelect)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        if let checked = choice.checked {
          Image(systemName: checked ? "checkmark.square.fill" : "square")
            .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .accessibilityLabel(checked ? Text("Checked") : Text("Not checked"))
        } else {
          Text(choice.id)
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 16)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(choice.label).font(.body).multilineTextAlignment(.leading)
          if let description = choice.description, !description.isEmpty {
            Text(description).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
          }
        }
        Spacer(minLength: 4)
        if isSending {
          ProgressView().controlSize(.small)
        } else if isSent {
          Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(.tint)
        }
      }
      .padding(.horizontal, 12).padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSent ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color(.tertiarySystemFill)),
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .contentShape(.rect(cornerRadius: 14))
    }
    .buttonStyle(.plain)
    .disabled(isLocked)
    .accessibilityIdentifier("prompt-choice-\(choice.id)")
    .help(isMultiSelect ? "Check or uncheck \(choice.label) on the Mac" : "Answer with \(choice.label) on the Mac")
  }

  /// Multi-select: sends the checked boxes. Claude then shows its review page, a new prompt.
  private var submitButton: some View {
    let isSending = sentChoice == MirrorSession.submitChoice && answer?.state == .sending
    return Button {
      respond(MirrorSession.submitChoice, false)
    } label: {
      HStack {
        Text("Submit").font(.body.weight(.semibold))
        Spacer(minLength: 4)
        if isSending { ProgressView().controlSize(.small) }
      }
      .padding(.horizontal, 12).padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect(cornerRadius: 14))
    }
    .buttonStyle(.glassProminent)
    .disabled(isLocked)
    .accessibilityIdentifier("prompt-submit")
    .help("Submit the checked answers on the Mac")
  }

  private var kindTitle: String {
    switch prompt.kind {
    case .permission: String(localized: "Blocked · Permission")
    case .question: String(localized: "Blocked · Question")
    case .planApproval: String(localized: "Blocked · Plan approval")
    case .auth: String(localized: "Blocked · Sign-in")
    case .trust: String(localized: "Blocked · Trust")
    case .elicitation: String(localized: "Blocked · Input")
    }
  }
}

extension MirrorConversationStore {
  /// The newest screen prompt that is still open: the one a phone can answer (docs-ai 089 S4).
  var openScreenPrompt: MirrorConversationEvent.Prompt? {
    for item in items.reversed() {
      if case .prompt(_, let prompt, nil, _) = item, prompt.id.hasPrefix("screen:") { return prompt }
    }
    return nil
  }
}
