import AppKit
import CoreText
import GhosttyKit

extension GhosttySurfaceView {
  override func mouseMoved(with event: NSEvent) {
    sendMousePosition(event)
    if let window, window.isKeyWindow, !focused, runtime.focusFollowsMouse() {
      requestFocus()
    }
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    sendMousePosition(event)
  }

  override func mouseExited(with event: NSEvent) {
    if NSEvent.pressedMouseButtons != 0 {
      return
    }
    guard let surface else { return }
    let mods = ghosttyMods(event.modifierFlags)
    ghostty_surface_mouse_pos(surface, -1, -1, mods)
  }

  override func mouseDown(with event: NSEvent) {
    sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
  }

  override func mouseUp(with event: NSEvent) {
    prevPressureStage = 0
    sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    if let surface {
      ghostty_surface_mouse_pressure(surface, 0, 0)
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    guard let surface else {
      super.rightMouseDown(with: event)
      return
    }
    let mods = ghosttyMods(event.modifierFlags)
    if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods) {
      return
    }
    super.rightMouseDown(with: event)
  }

  override func rightMouseUp(with event: NSEvent) {
    guard let surface else {
      super.rightMouseUp(with: event)
      return
    }
    let mods = ghosttyMods(event.modifierFlags)
    if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods) {
      return
    }
    super.rightMouseUp(with: event)
  }

  override func otherMouseDown(with event: NSEvent) {
    sendMouseButton(
      event, state: GHOSTTY_MOUSE_PRESS, button: Self.ghosttyMouseButton(from: event.buttonNumber))
  }

  override func otherMouseUp(with event: NSEvent) {
    sendMouseButton(
      event, state: GHOSTTY_MOUSE_RELEASE, button: Self.ghosttyMouseButton(from: event.buttonNumber)
    )
  }

  static func ghosttyMouseButton(from buttonNumber: Int) -> ghostty_input_mouse_button_e {
    switch buttonNumber {
    case 0: GHOSTTY_MOUSE_LEFT
    case 1: GHOSTTY_MOUSE_RIGHT
    case 2: GHOSTTY_MOUSE_MIDDLE
    case 3: GHOSTTY_MOUSE_EIGHT
    case 4: GHOSTTY_MOUSE_NINE
    case 5: GHOSTTY_MOUSE_SIX
    case 6: GHOSTTY_MOUSE_SEVEN
    case 7: GHOSTTY_MOUSE_FOUR
    case 8: GHOSTTY_MOUSE_FIVE
    case 9: GHOSTTY_MOUSE_TEN
    case 10: GHOSTTY_MOUSE_ELEVEN
    default: GHOSTTY_MOUSE_UNKNOWN
    }
  }

  override func mouseDragged(with event: NSEvent) {
    sendMousePosition(event)
  }

  override func rightMouseDragged(with event: NSEvent) {
    sendMousePosition(event)
  }

  override func otherMouseDragged(with event: NSEvent) {
    sendMousePosition(event)
  }

  override func scrollWheel(with event: NSEvent) {
    if mirrorGrid != nil {
      enclosingScrollView?.scrollWheel(with: event)
      return
    }
    guard let surface else { return }
    var scrollX = event.scrollingDeltaX
    var scrollY = event.scrollingDeltaY
    if event.hasPreciseScrollingDeltas {
      scrollX *= 2
      scrollY *= 2
    }
    ghostty_surface_mouse_scroll(surface, scrollX, scrollY, scrollMods(for: event))
  }

  override func pressureChange(with event: NSEvent) {
    guard let surface else { return }
    ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    guard prevPressureStage < 2 else { return }
    prevPressureStage = event.stage
    guard event.stage == 2 else { return }
    guard UserDefaults.standard.bool(forKey: "com.apple.trackpad.forceClick") else { return }
    quickLook(with: event)
  }

  override func quickLook(with event: NSEvent) {
    guard let surface else { return super.quickLook(with: event) }
    var text = ghostty_text_s()
    guard ghostty_surface_quicklook_word(surface, &text) else {
      return super.quickLook(with: event)
    }
    defer { ghostty_surface_free_text(surface, &text) }
    guard text.text_len > 0 else { return super.quickLook(with: event) }

    var attributes: [NSAttributedString.Key: Any] = [:]
    if let fontRaw = ghostty_surface_quicklook_font(surface) {
      let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
      attributes[.font] = font.takeUnretainedValue()
      font.release()
    }

    let str = NSAttributedString(string: Self.string(from: text), attributes: attributes)
    let point = NSPoint(x: text.tl_px_x, y: frame.size.height - text.tl_px_y)
    showDefinition(for: str, at: point)
  }

  func localEventHandler(_ event: NSEvent) -> NSEvent? {
    switch event.type {
    case .keyUp:
      localEventKeyUp(event)
    case .leftMouseDown:
      localEventLeftMouseDown(event)
    case .flagsChanged:
      localEventFlagsChanged(event)
    default:
      event
    }
  }

  func localEventKeyUp(_ event: NSEvent) -> NSEvent? {
    if !event.modifierFlags.contains(.command) { return event }
    guard focused else { return event }
    keyUp(with: event)
    return nil
  }

  // The responder chain delivers flagsChanged only to the first responder, so forward it to
  // every other surface; a hovered but unfocused terminal still needs to refresh its links
  // (e.g. holding Cmd over a link in a non-focused split, without moving the mouse).
  func localEventFlagsChanged(_ event: NSEvent) -> NSEvent? {
    guard window != nil, window?.firstResponder !== self else { return event }
    flagsChanged(with: event)
    return event
  }

  func localEventLeftMouseDown(_ event: NSEvent) -> NSEvent? {
    guard let window, event.window != nil, window == event.window else { return event }
    let location = convert(event.locationInWindow, from: nil)
    guard hitTest(location) == self else { return event }
    guard !NSApp.isActive || !window.isKeyWindow else { return event }
    guard !focused else { return event }
    window.makeFirstResponder(self)
    return event
  }

  func scrollMods(for event: NSEvent) -> ghostty_input_scroll_mods_t {
    var value: Int32 = 0
    if event.hasPreciseScrollingDeltas {
      value |= 0b0000_0001
    }
    let momentum: Int32
    switch event.momentumPhase {
    case .began:
      momentum = 1
    case .stationary:
      momentum = 2
    case .changed:
      momentum = 3
    case .ended:
      momentum = 4
    case .cancelled:
      momentum = 5
    case .mayBegin:
      momentum = 6
    default:
      momentum = 0
    }
    value |= (momentum << 1)
    return ghostty_input_scroll_mods_t(value)
  }

  func sendMousePosition(_ event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    let yPosition = bounds.height - point.y
    let mods = ghosttyMods(event.modifierFlags)
    ghostty_surface_mouse_pos(surface, point.x, yPosition, mods)
  }

  func sendMouseButton(
    _ event: NSEvent,
    state: ghostty_input_mouse_state_e,
    button: ghostty_input_mouse_button_e
  ) {
    guard let surface else { return }
    let mods = ghosttyMods(event.modifierFlags)
    ghostty_surface_mouse_button(surface, state, button, mods)
  }

}
