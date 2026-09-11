import AppKit
import CoreText
import GhosttyKit

extension GhosttySurfaceView {
  func setAccessibilityPaneIndex(index: Int, total: Int) {
    guard total > 0, index > 0, index <= total else {
      accessibilityPaneIndexHelp = nil
      return
    }
    accessibilityPaneIndexHelp = "Pane \(index) of \(total)"
  }

  override func isAccessibilityElement() -> Bool {
    // Avoid interacting with panes after teardown.
    surface != nil
  }

  override func accessibilityRole() -> NSAccessibility.Role? {
    // Match Ghostty.app so speech/input tools can treat the surface as editable text.
    .textArea
  }

  override func accessibilityLabel() -> String? {
    let title = bridge.state.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !title.isEmpty {
      return title
    }
    let pwd = bridge.state.pwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !pwd.isEmpty {
      return pwd
    }
    return "Terminal pane"
  }

  override func accessibilityValue() -> Any? {
    cachedScreenContents.get()
  }

  override func accessibilityHelp() -> String? {
    accessibilityPaneIndexHelp
  }

  override func accessibilitySelectedTextRange() -> NSRange {
    selectedRange()
  }

  override func accessibilitySelectedText() -> String? {
    guard let surface else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    let value = Self.string(from: text)
    return value.isEmpty ? nil : value
  }

  override func accessibilityNumberOfCharacters() -> Int {
    cachedScreenContents.get().count
  }

  override func accessibilityVisibleCharacterRange() -> NSRange {
    let content = cachedScreenContents.get()
    return NSRange(location: 0, length: content.count)
  }

  override func accessibilityLine(for index: Int) -> Int {
    Self.accessibilityLine(for: index, in: cachedScreenContents.get())
  }

  override func accessibilityString(for range: NSRange) -> String? {
    Self.accessibilityString(for: range, in: cachedScreenContents.get())
  }

  override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
    guard let surface else { return nil }
    guard let plainString = accessibilityString(for: range) else { return nil }

    var attributes: [NSAttributedString.Key: Any] = [:]
    if let fontRaw = ghostty_surface_quicklook_font(surface) {
      let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
      attributes[.font] = font.takeUnretainedValue()
      font.release()
    }

    return NSAttributedString(string: plainString, attributes: attributes)
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
      focusDidChange(true)
      postAccessibilityFocusChanged()
    }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result {
      focusDidChange(false)
    }
    return result
  }

  func postAccessibilityFocusChanged() {
    guard surface != nil else { return }
    // Post on the window so assistive tech can query the focused element from it.
    if let window {
      NSAccessibility.post(element: window, notification: .focusedUIElementChanged)
    } else {
      NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }
  }

  func readText(
    topLeftTag: ghostty_point_tag_e,
    bottomRightTag: ghostty_point_tag_e
  ) -> String? {
    guard let surface else { return nil }
    var text = ghostty_text_s()
    let selection = ghostty_selection_s(
      top_left: ghostty_point_s(
        tag: topLeftTag,
        coord: GHOSTTY_POINT_COORD_TOP_LEFT,
        x: 0,
        y: 0
      ),
      bottom_right: ghostty_point_s(
        tag: bottomRightTag,
        coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
        x: 0,
        y: 0
      ),
      rectangle: false
    )
    guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    return Self.string(from: text)
  }

  func readScreenContents() -> String {
    readText(
      topLeftTag: GHOSTTY_POINT_SCREEN,
      bottomRightTag: GHOSTTY_POINT_SCREEN
    ) ?? ""
  }

  func readViewportContentsForCLI() -> String? {
    readText(
      topLeftTag: GHOSTTY_POINT_VIEWPORT,
      bottomRightTag: GHOSTTY_POINT_VIEWPORT
    )
  }

  func readStyledSnapshotForCLI() -> String? {
    guard let surface else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_read_snapshot(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    guard text.text_len <= 4 * 1024 * 1024 else { return nil }
    return Self.string(from: text)
  }

  func readActiveContentsForCLI() -> String? {
    readText(
      topLeftTag: GHOSTTY_POINT_ACTIVE,
      bottomRightTag: GHOSTTY_POINT_ACTIVE
    )
  }

  func readScreenContentsForCLI() -> String? {
    readText(
      topLeftTag: GHOSTTY_POINT_SCREEN,
      bottomRightTag: GHOSTTY_POINT_SCREEN
    )
  }

}
