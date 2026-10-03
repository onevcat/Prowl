import AppKit
import CoreText
import GhosttyKit

extension GhosttySurfaceView: NSTextInputClient {
  func hasMarkedText() -> Bool {
    markedText.length > 0
  }

  func markedRange() -> NSRange {
    guard markedText.length > 0 else { return NSRange() }
    return NSRange(location: 0, length: markedText.length)
  }

  func selectedRange() -> NSRange {
    guard let surface else { return NSRange() }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
    defer { ghostty_surface_free_text(surface, &text) }
    return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    switch string {
    case let attributedText as NSAttributedString:
      markedText = NSMutableAttributedString(attributedString: attributedText)
    case let stringValue as String:
      markedText = NSMutableAttributedString(string: stringValue)
    default:
      return
    }
    if markedText.length > 0 { recordEditingActivity() }
    if keyTextAccumulator == nil {
      syncPreedit()
    }
  }

  func unmarkText() {
    if markedText.length > 0 {
      markedText.mutableString.setString("")
      syncPreedit()
    }
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    []
  }

  func attributedSubstring(
    forProposedRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSAttributedString? {
    guard let surface else { return nil }
    guard range.length > 0 else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    var attributes: [NSAttributedString.Key: Any] = [:]
    if let fontRaw = ghostty_surface_quicklook_font(surface) {
      let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
      attributes[.font] = font.takeUnretainedValue()
      font.release()
    }
    return NSAttributedString(string: Self.string(from: text), attributes: attributes)
  }

  func characterIndex(for point: NSPoint) -> Int {
    0
  }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let surface else {
      return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
    }
    var caretX: Double = 0
    var caretY: Double = 0
    var width: Double = cellSize.width
    var height: Double = cellSize.height
    if range.length > 0, range != selectedRange() {
      var text = ghostty_text_s()
      if ghostty_surface_read_selection(surface, &text) {
        caretX = text.tl_px_x - 2
        caretY = text.tl_px_y + 2
        ghostty_surface_free_text(surface, &text)
      } else {
        ghostty_surface_ime_point(surface, &caretX, &caretY, &width, &height)
      }
    } else {
      ghostty_surface_ime_point(surface, &caretX, &caretY, &width, &height)
    }
    if range.length == 0, width > 0 {
      width = 0
      caretX += cellSize.width * Double(range.location + range.length)
    }
    let viewRect = NSRect(
      x: caretX,
      y: frame.size.height - caretY,
      width: width,
      height: max(height, cellSize.height)
    )
    let winRect = convert(viewRect, to: nil)
    guard let window else { return winRect }
    return window.convertToScreen(winRect)
  }

  func insertText(_ string: Any, replacementRange _: NSRange) {
    guard NSApp.currentEvent != nil else { return }
    guard surface != nil else { return }
    var chars = ""
    switch string {
    case let attributedText as NSAttributedString:
      chars = attributedText.string
    case let stringValue as String:
      chars = stringValue
    default:
      return
    }
    unmarkText()
    if var acc = keyTextAccumulator {
      acc.append(chars)
      keyTextAccumulator = acc
      onCommittedText?(chars)
      return
    }
    insertCommittedTextForBroadcast(chars)
    onCommittedText?(chars)
  }

  func insertCommittedTextForBroadcast(_ text: String) {
    guard let surface else { return }
    guard !text.isEmpty else { return }
    recordEditingActivity()
    unmarkText()
    let len = text.utf8CString.count
    guard len > 0 else { return }
    text.withCString { ptr in
      ghostty_surface_text(surface, ptr, UInt(len - 1))
    }
  }

  @discardableResult
  func applyMirroredKeyForBroadcast(_ key: MirroredTerminalKey) -> Bool {
    let windowNumber = window?.windowNumber ?? 0
    guard let keyDownEvent = key.keyDownEvent(windowNumber: windowNumber) else {
      return false
    }
    keyDown(with: keyDownEvent)
    if !key.isRepeat,
      let keyUpEvent = key.keyUpEvent(windowNumber: windowNumber)
    {
      keyUp(with: keyUpEvent)
    }
    return true
  }

  @discardableResult
  func submitLine() -> Bool {
    let timestamp = ProcessInfo.processInfo.systemUptime
    let windowNumber = window?.windowNumber ?? 0
    guard
      let keyDownEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: windowNumber,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: 36
      ),
      let keyUpEvent = NSEvent.keyEvent(
        with: .keyUp,
        location: .zero,
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: windowNumber,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: 36
      )
    else {
      return false
    }
    keyDown(with: keyDownEvent)
    keyUp(with: keyUpEvent)
    return true
  }

  // MARK: - CLI key token delivery

  /// Send a single key event for a canonical CLI token (e.g. "enter", "ctrl-c", "pageup").
  /// Creates synthetic keyDown/keyUp NSEvents matching the token spec.
  @discardableResult
  func sendCLIKeyToken(_ token: String) -> Bool {
    guard surface != nil else { return false }
    guard let spec = CLIKeySpec.from(token: token) else { return false }
    let timestamp = ProcessInfo.processInfo.systemUptime
    let windowNumber = window?.windowNumber ?? 0
    guard
      let keyDownEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: spec.modifiers,
        timestamp: timestamp,
        windowNumber: windowNumber,
        context: nil,
        characters: spec.characters,
        charactersIgnoringModifiers: spec.charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: spec.keyCode
      ),
      let keyUpEvent = NSEvent.keyEvent(
        with: .keyUp,
        location: .zero,
        modifierFlags: spec.modifiers,
        timestamp: timestamp,
        windowNumber: windowNumber,
        context: nil,
        characters: spec.characters,
        charactersIgnoringModifiers: spec.charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: spec.keyCode
      )
    else {
      return false
    }
    keyDown(with: keyDownEvent)
    keyUp(with: keyUpEvent)
    return true
  }
}
