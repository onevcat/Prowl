import AppKit
import SwiftUI

struct PlainTextEditor: NSViewRepresentable {
  @Binding var text: String
  var isMonospaced: Bool = false
  var shouldFocus: Bool = false
  var placeholder: String?
  var hidesPlaceholderWhenFocused: Bool = false

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = PlaceholderTextView(frame: .zero)
    textView.delegate = context.coordinator
    textView.drawsBackground = false
    textView.isRichText = false
    textView.importsGraphics = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.font = editorFont
    textView.textContainerInset = NSSize(width: 4, height: 6)
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.string = text
    textView.placeholder = placeholder
    textView.hidesPlaceholderWhenFocused = hidesPlaceholderWhenFocused

    let scrollView = NSScrollView(frame: .zero)
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? PlaceholderTextView else { return }
    // Sync from state, but skip stale echoes of an in-flight user edit: resetting to an
    // older value would clobber newer text and jump the caret (#608).
    if textView.string == text {
      context.coordinator.lastPushedText = nil
    } else if textView.string != context.coordinator.lastPushedText {
      let selectedRange = textView.selectedRange()
      textView.string = text
      let selectedLocation = min(selectedRange.location, text.utf16.count)
      let selectedLength = min(selectedRange.length, text.utf16.count - selectedLocation)
      textView.setSelectedRange(NSRange(location: selectedLocation, length: selectedLength))
      textView.needsDisplay = true
    }
    let updatedFont = editorFont
    if textView.font != updatedFont {
      textView.font = updatedFont
      textView.needsDisplay = true
    }
    textView.placeholder = placeholder
    textView.hidesPlaceholderWhenFocused = hidesPlaceholderWhenFocused
    if shouldFocus,
      textView.window?.firstResponder !== textView
    {
      textView.window?.makeFirstResponder(textView)
    }
  }

  private var editorFont: NSFont {
    if isMonospaced {
      return NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }
    return NSFont.preferredFont(forTextStyle: .body)
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String

    /// Last text pushed to the binding from a user edit; cleared by `updateNSView`
    /// once the value round-trips back from state.
    var lastPushedText: String?

    init(text: Binding<String>) {
      _text = text
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? PlaceholderTextView else { return }
      lastPushedText = textView.string
      text = textView.string
      textView.needsDisplay = true
    }
  }

  final class PlaceholderTextView: NSTextView {
    var placeholder: String? {
      didSet {
        needsDisplay = true
      }
    }
    var hidesPlaceholderWhenFocused: Bool = true {
      didSet {
        needsDisplay = true
      }
    }

    override func becomeFirstResponder() -> Bool {
      let didBecomeFirstResponder = super.becomeFirstResponder()
      if didBecomeFirstResponder {
        needsDisplay = true
      }
      return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
      let didResignFirstResponder = super.resignFirstResponder()
      if didResignFirstResponder {
        needsDisplay = true
      }
      return didResignFirstResponder
    }

    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      drawPlaceholderIfNeeded()
    }

    private func drawPlaceholderIfNeeded() {
      guard let placeholder,
        !placeholder.isEmpty,
        string.isEmpty
      else {
        return
      }

      if hidesPlaceholderWhenFocused,
        window?.firstResponder === self
      {
        return
      }

      let lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
      let horizontalInset = textContainerInset.width + lineFragmentPadding
      let verticalInset = textContainerInset.height - 2
      let placeholderRect = NSRect(
        x: bounds.minX + horizontalInset,
        y: bounds.minY + verticalInset,
        width: max(0, bounds.width - horizontalInset - textContainerInset.width),
        height: max(0, bounds.height - verticalInset)
      )
      let placeholderAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.placeholderTextColor,
        .font: font ?? NSFont.preferredFont(forTextStyle: .body),
      ]
      (placeholder as NSString).draw(in: placeholderRect, withAttributes: placeholderAttributes)
    }
  }
}
