import AppKit

/// Clipboard confirmations follow Ghostty's macOS app: a surface keeps at most
/// one request, a newer request replaces (and denies) the older one, and the
/// sheet shows only while the surface is focused, so a background pane cannot
/// steal focus. A background request rings the pane's bell instead.
extension GhosttySurfaceView {
  func requestClipboardConfirmation(_ confirmation: GhosttyClipboardConfirmation) {
    let previous = pendingClipboardConfirmation
    pendingClipboardConfirmation = confirmation
    if let previous, previous !== confirmation {
      dismissClipboardConfirmationAlert()
      previous.deny()
    }
    guard focused, window != nil else {
      bridge.state.bellCount += 1
      return
    }
    presentPendingClipboardConfirmation()
  }

  func presentPendingClipboardConfirmation() {
    guard
      clipboardConfirmationAlert == nil,
      focused,
      let window,
      let confirmation = pendingClipboardConfirmation
    else { return }

    let alert = Self.makeClipboardConfirmationAlert(for: confirmation)
    clipboardConfirmationAlert = alert
    // Return, Enter, and Escape all choose the safe button. The preview text
    // view would otherwise take Return, and NSAlert gives Escape only to a
    // button titled "Cancel".
    let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert] event in
      guard let alert, event.window === alert.window, [36, 53, 76].contains(event.keyCode) else { return event }
      alert.buttons.first?.performClick(nil)
      return nil
    }
    alert.beginSheetModal(for: window) { [weak self, weak alert] response in
      MainActor.assumeIsolated {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        guard let self, let alert, self.clipboardConfirmationAlert === alert else { return }
        self.clipboardConfirmationAlert = nil
        if self.pendingClipboardConfirmation === confirmation {
          self.pendingClipboardConfirmation = nil
        }
        if response == .alertSecondButtonReturn {
          confirmation.allow(remember: alert.suppressionButton?.state == .on)
        } else {
          confirmation.deny()
        }
      }
    }
  }

  func denyPendingClipboardConfirmation() {
    dismissClipboardConfirmationAlert()
    let confirmation = pendingClipboardConfirmation
    pendingClipboardConfirmation = nil
    confirmation?.deny()
  }

  private func dismissClipboardConfirmationAlert() {
    guard let alert = clipboardConfirmationAlert else { return }
    clipboardConfirmationAlert = nil
    alert.window.sheetParent?.endSheet(alert.window)
  }

  private static func makeClipboardConfirmationAlert(for confirmation: GhosttyClipboardConfirmation) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = confirmation.kind.messageText
    alert.informativeText = confirmation.kind.informativeText
    alert.accessoryView = previewView(confirmation.preview)
    // The safe choice is the default button, so a stray Return cannot paste
    // or disclose the clipboard. The key equivalent marks it as the default;
    // the key monitor in `presentPendingClipboardConfirmation` handles keys.
    alert.addButton(withTitle: confirmation.kind.cancelButtonTitle).keyEquivalent = "\r"
    alert.addButton(withTitle: confirmation.kind.confirmButtonTitle)
    if confirmation.canRemember {
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = String(localized: "Remember this choice for this session")
    }
    return alert
  }

  private static func previewView(_ preview: GhosttyClipboardPreview) -> NSView {
    let frame = NSRect(x: 0, y: 0, width: 480, height: 160)
    if let data = preview.imageData, let image = NSImage(data: data) {
      let imageView = NSImageView(frame: frame)
      imageView.image = image
      imageView.imageScaling = .scaleProportionallyDown
      imageView.setAccessibilityLabel(String(localized: "Clipboard image"))
      return imageView
    }

    let scrollView = NSScrollView(frame: frame)
    scrollView.borderType = .bezelBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let textView = NSTextView(frame: scrollView.contentView.bounds)
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.string = preview.text
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: scrollView.contentSize.width,
      height: .greatestFiniteMagnitude
    )
    textView.setAccessibilityLabel(String(localized: "Clipboard contents"))
    scrollView.documentView = textView
    return scrollView
  }
}
