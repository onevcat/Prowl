import AppKit
import Carbon

enum AgentIslandHotKeyAction: Equatable {
  case toggleIslandRoster
  case collapseIsland

  static func resolve(
    isRosterExpanded: Bool,
    hasEntries: Bool
  ) -> Self? {
    if isRosterExpanded {
      return .collapseIsland
    }
    return hasEntries ? .toggleIslandRoster : nil
  }
}

enum AgentIslandKeyboardCommand: Equatable {
  case collapse
  case move(ActiveAgentsFeature.NavigationDirection)
  case page(ActiveAgentsFeature.NavigationDirection)
  case activateSelection
  case activateVisibleEntry(Int)

  static func resolve(
    keyCode: UInt16,
    characters: String?,
    modifiers: NSEvent.ModifierFlags
  ) -> Self? {
    let significantModifiers = modifiers.intersection([.command, .shift, .option, .control])
    if let index = numberIndex(for: keyCode) {
      return .activateVisibleEntry(index)
    }
    guard significantModifiers.isEmpty else { return nil }

    switch keyCode {
    case 53:
      return .collapse
    case 126:
      return .move(.previous)
    case 125:
      return .move(.next)
    case 123:
      return .page(.previous)
    case 124:
      return .page(.next)
    case 36, 49, 76:
      return .activateSelection
    default:
      break
    }

    switch characters?.lowercased() {
    case "k":
      return .move(.previous)
    case "j":
      return .move(.next)
    case "h":
      return .page(.previous)
    case "l":
      return .page(.next)
    default:
      return nil
    }
  }

  private static func numberIndex(for keyCode: UInt16) -> Int? {
    switch keyCode {
    case 18, 83: return 0
    case 19, 84: return 1
    case 20, 85: return 2
    case 21, 86: return 3
    case 23, 87: return 4
    case 22, 88: return 5
    case 26, 89: return 6
    case 28, 91: return 7
    case 25, 92: return 8
    default: return nil
    }
  }
}

enum AgentIslandGlobalHotKeyCommand: Equatable {
  case toggleRoster

  fileprivate var identifier: UInt32 {
    1
  }

  fileprivate init?(identifier: UInt32) {
    guard identifier == Self.toggleRoster.identifier else { return nil }
    self = .toggleRoster
  }
}

struct AgentIslandGlobalHotKeyConfiguration: Equatable {
  let configuredBinding: Keybinding?
  let binding: Keybinding?

  init(
    toggleBinding: Keybinding?,
    hasEntries: Bool,
    isAppActive: Bool
  ) {
    configuredBinding = toggleBinding
    binding = hasEntries && !isAppActive ? toggleBinding : nil
  }

  func requiresRefresh(from previous: Self?, force: Bool = false) -> Bool {
    force || previous != self
  }
}

enum IslandHotKeyRegistrationResult: Equatable {
  case inactive
  case registered
  case failed
}

@MainActor
enum AgentIslandShortcutEventMatcher {
  static func matches(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifiers: NSEvent.ModifierFlags,
    binding: Keybinding?
  ) -> Bool {
    guard let binding else { return false }
    let token = ShortcutKeyTokenResolver().resolveKeyToken(
      keyCode: keyCode,
      charactersIgnoringModifiers: charactersIgnoringModifiers
    )
    let keyMatches = token == binding.key || token == physicalDigitToken(for: binding.key)
    guard keyMatches else { return false }
    let significantModifiers = modifiers.intersection([.command, .shift, .option, .control])
    return significantModifiers.contains(.command) == binding.modifiers.command
      && significantModifiers.contains(.shift) == binding.modifiers.shift
      && significantModifiers.contains(.option) == binding.modifiers.option
      && significantModifiers.contains(.control) == binding.modifiers.control
  }

  private static func physicalDigitToken(for key: String) -> String? {
    guard key.count == 1, key.first?.isNumber == true else { return nil }
    return "digit_\(key)"
  }
}

private struct AgentIslandCarbonHotKeyDescriptor {
  let keyCode: UInt32
  let modifiers: UInt32

  @MainActor
  init?(binding: Keybinding) {
    let resolver = ShortcutKeyTokenResolver()
    guard
      let keyCode = (0..<128).first(where: { candidate in
        let token = resolver.resolveKeyToken(
          keyCode: UInt16(candidate),
          charactersIgnoringModifiers: nil
        )
        return token == binding.key || token == Self.physicalDigitToken(for: binding.key)
      })
    else {
      return nil
    }

    var carbonModifiers: UInt32 = 0
    if binding.modifiers.command { carbonModifiers |= UInt32(cmdKey) }
    if binding.modifiers.shift { carbonModifiers |= UInt32(shiftKey) }
    if binding.modifiers.option { carbonModifiers |= UInt32(optionKey) }
    if binding.modifiers.control { carbonModifiers |= UInt32(controlKey) }
    guard carbonModifiers != 0 else { return nil }

    self.keyCode = UInt32(keyCode)
    self.modifiers = carbonModifiers
  }

  private static func physicalDigitToken(for key: String) -> String? {
    guard key.count == 1, key.first?.isNumber == true else { return nil }
    return "digit_\(key)"
  }
}

@MainActor
final class AgentIslandGlobalHotKeys {
  private static let signature: OSType = 0x5052_574C  // PRWL
  private static let logger = SupaLogger("AgentIsland")

  private var eventHandler: EventHandlerRef?
  private var hotKeys: [UInt32: EventHotKeyRef] = [:]
  private let action: @MainActor (AgentIslandGlobalHotKeyCommand) -> Void

  init(action: @escaping @MainActor (AgentIslandGlobalHotKeyCommand) -> Void) {
    self.action = action
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID
        )
        guard status == noErr,
          hotKeyID.signature == AgentIslandGlobalHotKeys.signature,
          let command = AgentIslandGlobalHotKeyCommand(identifier: hotKeyID.id)
        else {
          return OSStatus(eventNotHandledErr)
        }
        let registrar = Unmanaged<AgentIslandGlobalHotKeys>.fromOpaque(userData)
          .takeUnretainedValue()
        MainActor.assumeIsolated {
          registrar.action(command)
        }
        return noErr
      },
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )
    if status != noErr {
      Self.logger.warning("hot_key_handler_install_failed status=\(status)")
    }
  }

  isolated deinit {
    stop()
  }

  func register(binding: Keybinding?) -> IslandHotKeyRegistrationResult {
    register(command: .toggleRoster, binding: binding)
  }

  private func register(
    command: AgentIslandGlobalHotKeyCommand,
    binding: Keybinding?
  ) -> IslandHotKeyRegistrationResult {
    unregister(command: command)
    guard let binding else { return .inactive }
    guard eventHandler != nil else {
      Self.logger.warning("hot_key_registration_failed reason=handler_unavailable binding=\(binding.display)")
      return .failed
    }
    guard let descriptor = AgentIslandCarbonHotKeyDescriptor(binding: binding) else {
      Self.logger.warning("hot_key_registration_failed reason=unsupported_binding binding=\(binding.display)")
      return .failed
    }
    let hotKeyID = EventHotKeyID(signature: Self.signature, id: command.identifier)
    var hotKey: EventHotKeyRef?
    let status = RegisterEventHotKey(
      descriptor.keyCode,
      descriptor.modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
    if status == noErr, let hotKey {
      hotKeys[command.identifier] = hotKey
      return .registered
    } else {
      Self.logger.warning("hot_key_registration_failed binding=\(binding.display) status=\(status)")
      return .failed
    }
  }

  private func unregister(command: AgentIslandGlobalHotKeyCommand) {
    if let hotKey = hotKeys.removeValue(forKey: command.identifier) {
      UnregisterEventHotKey(hotKey)
    }
  }

  func stop() {
    for hotKey in hotKeys.values {
      UnregisterEventHotKey(hotKey)
    }
    hotKeys.removeAll()
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }
}
