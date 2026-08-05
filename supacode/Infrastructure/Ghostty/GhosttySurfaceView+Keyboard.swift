import AppKit
import Carbon
import GhosttyKit
import SwiftUI

extension GhosttySurfaceView {
  override func keyDown(with event: NSEvent) {
    guard let surface else {
      interpretKeyEvents([event])
      return
    }
    bridge.state.bellCount = 0
    onKeyInput?()
    if let mirroredKey = MirroredTerminalKey(event: event) {
      onMirroredKey?(mirroredKey)
    }
    let (translationEvent, translationMods) = translationState(event, surface: surface)
    let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
    keyTextAccumulator = []
    defer { keyTextAccumulator = nil }
    let markedTextBefore = markedText.length > 0
    let keyboardIdBefore = markedTextBefore ? nil : keyboardLayoutId()
    lastPerformKeyEvent = nil
    interpretKeyEvents([translationEvent])
    if !markedTextBefore, keyboardIdBefore != keyboardLayoutId() {
      keyboardLayoutChangeKeyUpSuppression = KeyboardLayoutChangeKeyUpSuppression(
        keyCode: event.keyCode,
        timestamp: event.timestamp
      )
      return
    }
    syncPreedit(clearIfNeeded: markedTextBefore)
    if let list = keyTextAccumulator, !list.isEmpty {
      for text in list {
        _ = sendKey(
          action: action,
          event: event,
          translationEvent: translationEvent,
          translationMods: translationMods,
          text: text,
          composing: false
        )
      }
    } else {
      _ = sendKey(
        action: action,
        event: event,
        translationEvent: translationEvent,
        translationMods: translationMods,
        text: ghosttyCharacters(translationEvent),
        composing: markedText.length > 0 || markedTextBefore
      )
    }
  }

  override func keyUp(with event: NSEvent) {
    if suppressKeyboardLayoutChangeKeyUp(event) { return }
    sendKey(action: GHOSTTY_ACTION_RELEASE, event: event)
  }

  override func flagsChanged(with event: NSEvent) {
    let mod: UInt32
    switch event.keyCode {
    case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
    case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
    case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
    case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
    case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
    default: return
    }
    if hasMarkedText() { return }
    let mods = ghosttyMods(event.modifierFlags)
    var action = GHOSTTY_ACTION_RELEASE
    if (mods.rawValue & mod) != 0 {
      let sidePressed: Bool
      switch event.keyCode {
      case 0x3C:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
      case 0x3E:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
      case 0x3D:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
      case 0x36:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
      default:
        sidePressed = true
      }
      if sidePressed {
        action = GHOSTTY_ACTION_PRESS
      }
    }
    sendKey(action: action, event: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    let isFontSizeShortcut = matchesFontSizeShortcut(event: event)
    guard let surface else { return false }
    guard
      Self.hasKeyEquivalentFocusOwnership(
        cachedFocused: focused,
        isActualFirstResponder: window?.firstResponder === self
      )
    else { return false }

    if UserCustomShortcutRegistry.shared.matches(event: event),
      let menu = NSApp.mainMenu,
      Self.mainMenuHasMatchingItem(for: event, in: menu),
      menu.performKeyEquivalent(with: event)
    {
      return true
    }

    if let bindingFlags = bindingFlags(for: event, surface: surface) {
      if shouldAttemptMenu(for: bindingFlags),
        let menu = NSApp.mainMenu,
        Self.mainMenuHasMatchingItem(for: event, in: menu),
        menu.performKeyEquivalent(with: event)
      {
        return true
      }
      keyDown(with: event)
      if isFontSizeShortcut {
        onFontSizeShortcut?()
      }
      // Ghostty handled paste internally; broadcast the pasted text to followers.
      if onCommittedText != nil,
        event.modifierFlags.contains(.command),
        event.charactersIgnoringModifiers == "v",
        let text = NSPasteboard.general.string(forType: .string),
        !text.isEmpty
      {
        onCommittedText?(text)
      }
      return true
    }

    guard let equivalent = equivalentKey(for: event) else { return false }

    guard
      let finalEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: event.locationInWindow,
        modifierFlags: event.modifierFlags,
        timestamp: event.timestamp,
        windowNumber: event.windowNumber,
        context: nil,
        characters: equivalent,
        charactersIgnoringModifiers: equivalent,
        isARepeat: event.isARepeat,
        keyCode: event.keyCode
      )
    else {
      return false
    }
    keyDown(with: finalEvent)
    if isFontSizeShortcut {
      onFontSizeShortcut?()
    }
    return true
  }

  func matchesFontSizeShortcut(event: NSEvent) -> Bool {
    matchesBindingShortcut(event: event, action: "reset_font_size")
      || matchesBindingShortcut(event: event, action: "increase_font_size:1")
      || matchesBindingShortcut(event: event, action: "decrease_font_size:1")
  }

  func matchesBindingShortcut(event: NSEvent, action: String) -> Bool {
    guard let shortcut = runtime.keyboardShortcut(for: action) else { return false }
    let normalizedEventModifiers = normalizedModifiers(from: event.modifierFlags)
    guard normalizedEventModifiers == shortcut.modifiers else { return false }
    let eventKey = (event.charactersIgnoringModifiers ?? "").lowercased()
    let shortcutKey = String(shortcut.key.character).lowercased()
    return !eventKey.isEmpty && eventKey == shortcutKey
  }

  func normalizedModifiers(from flags: NSEvent.ModifierFlags) -> SwiftUI.EventModifiers {
    var normalized: SwiftUI.EventModifiers = []
    if flags.contains(.command) { normalized.insert(.command) }
    if flags.contains(.shift) { normalized.insert(.shift) }
    if flags.contains(.option) { normalized.insert(.option) }
    if flags.contains(.control) { normalized.insert(.control) }
    return normalized
  }

  func bindingFlags(
    for event: NSEvent,
    surface: ghostty_surface_t
  ) -> ghostty_binding_flags_e? {
    var key = ghosttyKeyEvent(
      event,
      action: GHOSTTY_ACTION_PRESS,
      originalMods: event.modifierFlags,
      translationMods: event.modifierFlags
    )
    var flags = ghostty_binding_flags_e(0)
    let isBinding = (event.characters ?? "").withCString { ptr in
      key.text = ptr
      return ghostty_surface_key_is_binding(surface, key, &flags)
    }
    return isBinding ? flags : nil
  }

  func equivalentKey(for event: NSEvent) -> String? {
    switch event.charactersIgnoringModifiers {
    case "\r":
      guard event.modifierFlags.contains(.control) else { return nil }
      return "\r"
    case "/":
      guard event.modifierFlags.contains(.control) else { return nil }
      guard event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return nil }
      return "_"
    default:
      if event.timestamp == 0 { return nil }
      if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
        lastPerformKeyEvent = nil
        return nil
      }
      if let lastPerformKeyEvent {
        self.lastPerformKeyEvent = nil
        if lastPerformKeyEvent == event.timestamp {
          return event.characters ?? ""
        }
      }
      lastPerformKeyEvent = event.timestamp
      return nil
    }
  }

  override func doCommand(by selector: Selector) {
    if let lastPerformKeyEvent,
      let current = NSApp.currentEvent,
      lastPerformKeyEvent == current.timestamp
    {
      NSApp.sendEvent(current)
      return
    }
    switch selector {
    case #selector(moveToBeginningOfDocument(_:)):
      performBindingAction("scroll_to_top")
    case #selector(moveToEndOfDocument(_:)):
      performBindingAction("scroll_to_bottom")
    default:
      break
    }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    switch event.type {
    case .rightMouseDown:
      break
    case .leftMouseDown:
      if !event.modifierFlags.contains(.control) {
        return nil
      }
      guard let surface else { return nil }
      if ghostty_surface_mouse_captured(surface) {
        return nil
      }
      let mods = ghosttyMods(event.modifierFlags)
      _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
    default:
      return nil
    }

    guard let surface else { return nil }
    if ghostty_surface_mouse_captured(surface) {
      return nil
    }

    let menu = NSMenu()
    if ghostty_surface_has_selection(surface) {
      menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""))
    }
    menu.addItem(NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(
      menuItem(
        title: "Split Right",
        action: #selector(splitRight(_:)),
        symbol: "rectangle.righthalf.inset.filled"
      ))
    menu.addItem(
      menuItem(
        title: "Split Left",
        action: #selector(splitLeft(_:)),
        symbol: "rectangle.leadinghalf.inset.filled"
      ))
    menu.addItem(
      menuItem(
        title: "Split Down",
        action: #selector(splitDown(_:)),
        symbol: "rectangle.bottomhalf.inset.filled"
      ))
    menu.addItem(
      menuItem(
        title: "Split Up",
        action: #selector(splitUp(_:)),
        symbol: "rectangle.tophalf.inset.filled"
      ))
    menu.addItem(.separator())
    menu.addItem(
      menuItem(
        title: "Reset Terminal",
        action: #selector(resetTerminal(_:)),
        symbol: "arrow.trianglehead.2.clockwise"
      ))
    menu.addItem(.separator())
    menu.addItem(
      menuItem(
        title: "Change Title...",
        action: #selector(changeTitle(_:)),
        symbol: "pencil.line"
      ))
    return menu
  }

  func menuItem(title: String, action: Selector, symbol: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    return item
  }

  @IBAction func splitRight(_ sender: Any?) {
    _ = bridge.onSplitAction?(.newSplit(direction: .right))
  }

  @IBAction func splitLeft(_ sender: Any?) {
    _ = bridge.onSplitAction?(.newSplit(direction: .left))
  }

  @IBAction func splitDown(_ sender: Any?) {
    _ = bridge.onSplitAction?(.newSplit(direction: .down))
  }

  @IBAction func splitUp(_ sender: Any?) {
    _ = bridge.onSplitAction?(.newSplit(direction: .top))
  }

  @IBAction func resetTerminal(_ sender: Any?) {
    performBindingAction("reset")
  }

  @IBAction func changeTitle(_ sender: Any?) {
    performBindingAction("prompt_surface_title")
  }

  static func hasKeyEquivalentFocusOwnership(
    cachedFocused: Bool,
    isActualFirstResponder: Bool
  ) -> Bool {
    cachedFocused && isActualFirstResponder
  }

  static func mainMenuHasMatchingItem(for event: NSEvent, in menu: NSMenu) -> Bool {
    let eventEquivalents = normalizedEventKeyEquivalents(for: event)
    guard !eventEquivalents.isEmpty else { return false }

    for item in menu.items {
      if let submenu = item.submenu, mainMenuHasMatchingItem(for: event, in: submenu) {
        return true
      }

      guard !item.keyEquivalent.isEmpty else { continue }
      guard
        let itemEquivalent = normalizedKeyEquivalent(
          key: item.keyEquivalent,
          modifiers: item.keyEquivalentModifierMask
        )
      else { continue }
      if eventEquivalents.contains(where: { $0 == itemEquivalent }) {
        return true
      }
    }

    return false
  }

  static let shortcutMask: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

  static let shiftedKeyEquivalentBases: [Character: Character] = [
    "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\",
    ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
  ]

  struct KeyEquivalentSignature: Equatable {
    var key: String
    var modifiers: NSEvent.ModifierFlags
  }

  static func normalizedEventKeyEquivalents(for event: NSEvent) -> [KeyEquivalentSignature] {
    let eventModifiers = event.modifierFlags.intersection(shortcutMask)
    return [event.charactersIgnoringModifiers, event.characters]
      .compactMap { characters in
        characters.flatMap { normalizedKeyEquivalent(key: $0, modifiers: eventModifiers) }
      }
      .reduce(into: []) { result, equivalent in
        if !result.contains(equivalent) {
          result.append(equivalent)
        }
      }
  }

  static func normalizedKeyEquivalent(
    key: String,
    modifiers: NSEvent.ModifierFlags
  ) -> KeyEquivalentSignature? {
    guard !key.isEmpty else { return nil }

    var normalizedKey = key.lowercased()
    var normalizedModifiers = modifiers.intersection(shortcutMask)

    if key.count == 1, let character = key.first {
      if let base = shiftedKeyEquivalentBases[character] {
        normalizedKey = String(base)
        normalizedModifiers.insert(.shift)
      } else if normalizedKey != key {
        normalizedModifiers.insert(.shift)
      }
    }

    return KeyEquivalentSignature(key: normalizedKey, modifiers: normalizedModifiers)
  }

  func shouldAttemptMenu(for flags: ghostty_binding_flags_e) -> Bool {
    if bridge.state.keySequenceActive == true { return false }
    if bridge.state.keyTableDepth > 0 { return false }
    let raw = flags.rawValue
    let isAll = (raw & GHOSTTY_BINDING_FLAGS_ALL.rawValue) != 0
    let isPerformable = (raw & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) != 0
    let isConsumed = (raw & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue) != 0
    return !isAll && !isPerformable && isConsumed
  }

  @IBAction func copy(_ sender: Any?) {
    performBindingAction("copy_to_clipboard")
  }

  @IBAction func paste(_ sender: Any?) {
    performBindingAction("paste_from_clipboard")
    if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
      onCommittedText?(text)
    }
  }

  @IBAction func pasteSelection(_ sender: Any?) {
    performBindingAction("paste_from_selection")
  }

  @IBAction override func selectAll(_ sender: Any?) {
    performBindingAction("select_all")
  }

  @discardableResult
  func sendKey(
    action: ghostty_input_action_e,
    event: NSEvent,
    translationEvent: NSEvent? = nil,
    translationMods: NSEvent.ModifierFlags? = nil,
    text: String? = nil,
    composing: Bool = false
  ) -> Bool {
    guard let surface else { return false }
    let resolvedEvent: NSEvent
    let resolvedMods: NSEvent.ModifierFlags
    if let translationEvent, let translationMods {
      resolvedEvent = translationEvent
      resolvedMods = translationMods
    } else {
      (resolvedEvent, resolvedMods) = translationState(event, surface: surface)
    }
    var key = ghosttyKeyEvent(
      resolvedEvent,
      action: action,
      originalMods: event.modifierFlags,
      translationMods: resolvedMods,
      composing: composing
    )
    let finalText = text ?? ghosttyCharacters(resolvedEvent)
    if let finalText, !finalText.isEmpty,
      let codepoint = finalText.utf8.first, codepoint >= 0x20
    {
      return finalText.withCString { ptr in
        key.text = ptr
        return ghostty_surface_key(surface, key)
      }
    }
    key.text = nil
    return ghostty_surface_key(surface, key)
  }

  func performBindingAction(_ action: String) {
    guard let surface else { return }
    _ = action.withCString { ptr in
      ghostty_surface_binding_action(surface, ptr, UInt(action.lengthOfBytes(using: .utf8)))
    }
  }

}
