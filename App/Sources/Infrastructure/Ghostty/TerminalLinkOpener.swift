import AppKit

/// Opens a `TerminalLink` at the AppKit boundary: directly, after a
/// confirmation, or not at all with an alert that says why.
enum TerminalLinkOpener {
  static func open(_ link: TerminalLink) {
    let decision = link.decision
    let displayString = link.displayString
    // The action callback runs while libghostty holds the renderer lock.
    // Present on the next main-loop turn so AppKit cannot reenter a render
    // callback before the lock is released.
    DispatchQueue.main.async {
      switch decision {
      case .allow(let url):
        NSWorkspace.shared.open(url)
      case .confirm(let url):
        presentConfirmation(for: url, displayString: displayString)
      case .deny(let reason):
        presentBlock(reason: reason, displayString: displayString)
      }
    }
  }

  private static func presentConfirmation(for url: URL, displayString: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(localized: "Open Link from Terminal Output?")
    if let handler = NSWorkspace.shared.urlForApplication(toOpen: url) {
      let name = handler.deletingPathExtension().lastPathComponent
      alert.informativeText = String(
        localized: "This link opens in \(name). Continue only if you recognize and trust the destination."
      )
    } else {
      alert.informativeText = String(
        localized: "This link opens in its default app. Continue only if you recognize and trust the destination."
      )
    }
    alert.accessoryView = targetView(displayString)
    // Cancel is the default button on purpose.
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.addButton(withTitle: String(localized: "Open Link"))
    present(alert) { response in
      guard response == .alertSecondButtonReturn else { return }
      NSWorkspace.shared.open(url)
    }
  }

  private static func presentBlock(reason: TerminalLink.DenialReason, displayString: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(localized: "Prowl Blocked This Link")
    alert.informativeText = reason.message
    alert.accessoryView = targetView(displayString)
    alert.addButton(withTitle: String(localized: "OK"))
    alert.addButton(withTitle: String(localized: "Copy Link"))
    present(alert) { response in
      // Copying the shown, sanitized target gives a way forward without a
      // one-click bypass of the policy.
      guard response == .alertSecondButtonReturn else { return }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(displayString, forType: .string)
    }
  }

  private static func present(
    _ alert: NSAlert,
    completion: @escaping (NSApplication.ModalResponse) -> Void
  ) {
    if let window = NSApp.keyWindow {
      alert.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(alert.runModal())
    }
  }

  private static func targetView(_ target: String) -> NSView {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
    scrollView.borderType = .bezelBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let textView = NSTextView(frame: scrollView.contentView.bounds)
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.string = target
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: scrollView.contentSize.width,
      height: .greatestFiniteMagnitude
    )
    textView.setAccessibilityLabel(String(localized: "Link target"))
    scrollView.documentView = textView
    return scrollView
  }
}
