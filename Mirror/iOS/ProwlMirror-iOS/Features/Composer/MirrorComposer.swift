import SwiftUI
import UIKit

struct MirrorComposer: UIViewRepresentable {
  @Bindable var session: MirrorSession
  @Binding var isEditing: Bool

  func makeUIView(context: Context) -> ComposerTextView {
    let view = ComposerTextView()
    view.font = .preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.backgroundColor = .secondarySystemBackground
    view.accessibilityIdentifier = "mirror-message-input"
    view.accessibilityLabel = "Write a message"
    view.delegate = context.coordinator
    view.onChange = { [weak session] text, composing in
      session?.isComposing = composing
      session?.draft = text
    }
    view.onSubmit = { [weak session] in session?.submitDraft() }
    view.onFocusChange = { isEditing = $0 }
    return view
  }

  func updateUIView(_ view: ComposerTextView, context: Context) {
    if view.text != session.draft, view.markedTextRange == nil {
      view.gesture.cancel()
      view.text = session.draft
    }
    view.canSubmit = session.canSubmit
    if !view.canSubmit { view.gesture.cancel() }
    if !isEditing, view.isFirstResponder { view.resignFirstResponder() }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context)
    -> CGSize?
  {
    guard let width = proposal.width, width > 0 else { return nil }
    let lineHeight =
      (uiView.font?.lineHeight ?? 22) + uiView.textContainerInset.top
      + uiView.textContainerInset.bottom
    let fullHeight = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      .height
    let height = isEditing ? min(max(lineHeight * 2, fullHeight), 168) : lineHeight
    return CGSize(width: width, height: height)
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, UITextViewDelegate {
    func textViewDidBeginEditing(_ textView: UITextView) {
      (textView as? ComposerTextView)?.onFocusChange?(true)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
      (textView as? ComposerTextView)?.onFocusChange?(false)
      textView.setContentOffset(.zero, animated: false)
    }

    func textViewDidChange(_ textView: UITextView) {
      guard let view = textView as? ComposerTextView else { return }
      view.gesture.validate(text: view.text, selection: view.selectedRange)
      view.reportChange()
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
      guard let view = textView as? ComposerTextView else { return }
      view.gesture.validate(text: view.text, selection: view.selectedRange)
      view.reportChange()
    }
  }
}

final class ComposerTextView: UITextView {
  var gesture = MirrorReturnGesture()
  var canSubmit = false
  var onChange: ((String, Bool) -> Void)?
  var onSubmit: (() -> Void)?
  var onFocusChange: ((Bool) -> Void)?
  private var returnHeld = false

  func reportChange() { onChange?(text, markedTextRange != nil) }

  override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
    gesture.cancel()
    super.setMarkedText(markedText, selectedRange: selectedRange)
    reportChange()
  }

  override func unmarkText() {
    gesture.cancel()
    super.unmarkText()
    reportChange()
  }

  override func resignFirstResponder() -> Bool {
    gesture.cancel()
    returnHeld = false
    return super.resignFirstResponder()
  }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard presses.count == 1, let key = presses.first?.key,
      key.keyCode == .keyboardReturnOrEnter, key.modifierFlags.isEmpty,
      markedTextRange == nil, canSubmit
    else {
      gesture.cancel()
      super.pressesBegan(presses, with: event)
      return
    }
    guard !returnHeld else {
      gesture.cancel()
      return
    }
    returnHeld = true
    let now = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
    if let submitted = gesture.consume(text: text, selection: selectedRange, time: now) {
      text = submitted
      reportChange()
      onSubmit?()
      return
    }
    let before = text ?? ""
    let selection = selectedRange
    // Own this physical Return so UIKit cannot deliver a second newline through
    // another key callback, and record the exact edit synchronously.
    insertText("\n")
    gesture.record(
      before: before, selection: selection, after: text,
      afterSelection: selectedRange, time: now)
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    if presses.contains(where: { $0.key?.keyCode == .keyboardReturnOrEnter }) { returnHeld = false }
    super.pressesEnded(presses, with: event)
  }

  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    returnHeld = false
    gesture.cancel()
    super.pressesCancelled(presses, with: event)
  }
}
