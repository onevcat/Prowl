// ProwlShared/KeyCommandPayload.swift
// Success payload for `prowl key --json` matching key.md contract.

import Foundation

public struct KeyCommandPayload: Codable, Sendable {
  public let requested: KeyRequested
  public let key: KeyInfo
  public let delivery: KeyDelivery
  public let target: KeyTarget

  public init(
    requested: KeyRequested,
    key: KeyInfo,
    delivery: KeyDelivery,
    target: KeyTarget
  ) {
    self.requested = requested
    self.key = key
    self.delivery = delivery
    self.target = target
  }
}

public struct KeyRequested: Codable, Sendable {
  public let token: String
  public let `repeat`: Int

  public init(token: String, repeat: Int) {
    self.token = token
    self.repeat = `repeat`
  }
}

public struct KeyInfo: Codable, Sendable {
  public let normalized: String
  public let category: KeyCategory

  public init(normalized: String, category: KeyCategory) {
    self.normalized = normalized
    self.category = category
  }
}

public enum KeyCategory: String, Codable, Sendable {
  case navigation
  case editing
  case control
  case shortcut
  case function
}

public struct KeyDelivery: Codable, Sendable {
  public let attempted: Int
  public let delivered: Int
  public let mode: String

  public init(attempted: Int, delivered: Int, mode: String = "keyDownUp") {
    self.attempted = attempted
    self.delivered = delivered
    self.mode = mode
  }
}

public struct KeyTarget: Codable, Sendable {
  public let worktree: KeyTargetWorktree
  public let tab: KeyTargetTab
  public let pane: KeyTargetPane

  public init(worktree: KeyTargetWorktree, tab: KeyTargetTab, pane: KeyTargetPane) {
    self.worktree = worktree
    self.tab = tab
    self.pane = pane
  }
}

public struct KeyTargetWorktree: Codable, Sendable {
  public let id: String
  public let name: String
  public let path: String
  public let rootPath: String
  public let kind: String

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case path
    case rootPath = "root_path"
    case kind
  }

  public init(id: String, name: String, path: String, rootPath: String, kind: String) {
    self.id = id
    self.name = name
    self.path = path
    self.rootPath = rootPath
    self.kind = kind
  }
}

public struct KeyTargetTab: Codable, Sendable {
  public let id: String
  public let title: String
  public let selected: Bool

  public init(id: String, title: String, selected: Bool) {
    self.id = id
    self.title = title
    self.selected = selected
  }
}

public struct KeyTargetPane: Codable, Sendable {
  public let id: String
  public let title: String
  public let cwd: String?
  public let focused: Bool

  public init(id: String, title: String, cwd: String?, focused: Bool) {
    self.id = id
    self.title = title
    self.cwd = cwd
    self.focused = focused
  }
}

// MARK: - Token Normalization

public enum KeyModifier: String, Codable, Sendable, CaseIterable {
  case cmd
  case shift
  case opt
  case ctrl

  static let canonicalOrder: [KeyModifier] = [.cmd, .shift, .opt, .ctrl]

  static func resolve(_ raw: String) -> KeyModifier? {
    switch raw {
    case "cmd", "command", "super":
      return .cmd
    case "shift":
      return .shift
    case "opt", "option", "alt":
      return .opt
    case "ctrl", "control":
      return .ctrl
    default:
      return nil
    }
  }
}

public struct KeyTokenDescriptor: Equatable, Sendable {
  public let normalized: String
  public let baseToken: String
  public let modifiers: [KeyModifier]
  public let category: KeyCategory

  public init(normalized: String, baseToken: String, modifiers: [KeyModifier], category: KeyCategory) {
    self.normalized = normalized
    self.baseToken = baseToken
    self.modifiers = modifiers
    self.category = category
  }
}

private struct KeyBaseDescriptor {
  let canonical: String
  let category: KeyCategory
}

private struct ResolvedKeyBaseDescriptor {
  let base: KeyBaseDescriptor
  let implicitModifiers: Set<KeyModifier>
}

/// Shared token definitions for the `key` command.
/// Used by CLI for validation and by app for response building.
public enum KeyTokens {
  private static let namedBaseDescriptors: [String: KeyBaseDescriptor] = [
    "enter": KeyBaseDescriptor(canonical: "enter", category: .editing),
    "return": KeyBaseDescriptor(canonical: "enter", category: .editing),
    "esc": KeyBaseDescriptor(canonical: "esc", category: .control),
    "escape": KeyBaseDescriptor(canonical: "esc", category: .control),
    "tab": KeyBaseDescriptor(canonical: "tab", category: .navigation),
    "backspace": KeyBaseDescriptor(canonical: "backspace", category: .editing),
    "delete": KeyBaseDescriptor(canonical: "backspace", category: .editing),
    "del": KeyBaseDescriptor(canonical: "backspace", category: .editing),
    "delete-forward": KeyBaseDescriptor(canonical: "delete-forward", category: .editing),
    "forward-delete": KeyBaseDescriptor(canonical: "delete-forward", category: .editing),
    "deleteforward": KeyBaseDescriptor(canonical: "delete-forward", category: .editing),
    "forwarddelete": KeyBaseDescriptor(canonical: "delete-forward", category: .editing),
    "insert": KeyBaseDescriptor(canonical: "insert", category: .editing),
    "ins": KeyBaseDescriptor(canonical: "insert", category: .editing),
    "up": KeyBaseDescriptor(canonical: "up", category: .navigation),
    "arrow-up": KeyBaseDescriptor(canonical: "up", category: .navigation),
    "down": KeyBaseDescriptor(canonical: "down", category: .navigation),
    "arrow-down": KeyBaseDescriptor(canonical: "down", category: .navigation),
    "left": KeyBaseDescriptor(canonical: "left", category: .navigation),
    "arrow-left": KeyBaseDescriptor(canonical: "left", category: .navigation),
    "right": KeyBaseDescriptor(canonical: "right", category: .navigation),
    "arrow-right": KeyBaseDescriptor(canonical: "right", category: .navigation),
    "pageup": KeyBaseDescriptor(canonical: "pageup", category: .navigation),
    "page-up": KeyBaseDescriptor(canonical: "pageup", category: .navigation),
    "pgup": KeyBaseDescriptor(canonical: "pageup", category: .navigation),
    "pagedown": KeyBaseDescriptor(canonical: "pagedown", category: .navigation),
    "page-down": KeyBaseDescriptor(canonical: "pagedown", category: .navigation),
    "pgdn": KeyBaseDescriptor(canonical: "pagedown", category: .navigation),
    "home": KeyBaseDescriptor(canonical: "home", category: .navigation),
    "end": KeyBaseDescriptor(canonical: "end", category: .navigation),
    "space": KeyBaseDescriptor(canonical: "space", category: .editing),
    "minus": KeyBaseDescriptor(canonical: "minus", category: .editing),
    "hyphen": KeyBaseDescriptor(canonical: "minus", category: .editing),
    "dash": KeyBaseDescriptor(canonical: "minus", category: .editing),
    "equal": KeyBaseDescriptor(canonical: "equal", category: .editing),
    "equals": KeyBaseDescriptor(canonical: "equal", category: .editing),
    "comma": KeyBaseDescriptor(canonical: "comma", category: .editing),
    "period": KeyBaseDescriptor(canonical: "period", category: .editing),
    "dot": KeyBaseDescriptor(canonical: "period", category: .editing),
    "slash": KeyBaseDescriptor(canonical: "slash", category: .editing),
    "backslash": KeyBaseDescriptor(canonical: "backslash", category: .editing),
    "semicolon": KeyBaseDescriptor(canonical: "semicolon", category: .editing),
    "quote": KeyBaseDescriptor(canonical: "quote", category: .editing),
    "apostrophe": KeyBaseDescriptor(canonical: "quote", category: .editing),
    "grave": KeyBaseDescriptor(canonical: "grave", category: .editing),
    "backtick": KeyBaseDescriptor(canonical: "grave", category: .editing),
    "left-bracket": KeyBaseDescriptor(canonical: "left-bracket", category: .editing),
    "leftbracket": KeyBaseDescriptor(canonical: "left-bracket", category: .editing),
    "lbracket": KeyBaseDescriptor(canonical: "left-bracket", category: .editing),
    "right-bracket": KeyBaseDescriptor(canonical: "right-bracket", category: .editing),
    "rightbracket": KeyBaseDescriptor(canonical: "right-bracket", category: .editing),
    "rbracket": KeyBaseDescriptor(canonical: "right-bracket", category: .editing),
  ]

  private static let singleCharacterBaseDescriptors: [String: KeyBaseDescriptor] = [
    "a": KeyBaseDescriptor(canonical: "a", category: .editing),
    "b": KeyBaseDescriptor(canonical: "b", category: .editing),
    "c": KeyBaseDescriptor(canonical: "c", category: .editing),
    "d": KeyBaseDescriptor(canonical: "d", category: .editing),
    "e": KeyBaseDescriptor(canonical: "e", category: .editing),
    "f": KeyBaseDescriptor(canonical: "f", category: .editing),
    "g": KeyBaseDescriptor(canonical: "g", category: .editing),
    "h": KeyBaseDescriptor(canonical: "h", category: .editing),
    "i": KeyBaseDescriptor(canonical: "i", category: .editing),
    "j": KeyBaseDescriptor(canonical: "j", category: .editing),
    "k": KeyBaseDescriptor(canonical: "k", category: .editing),
    "l": KeyBaseDescriptor(canonical: "l", category: .editing),
    "m": KeyBaseDescriptor(canonical: "m", category: .editing),
    "n": KeyBaseDescriptor(canonical: "n", category: .editing),
    "o": KeyBaseDescriptor(canonical: "o", category: .editing),
    "p": KeyBaseDescriptor(canonical: "p", category: .editing),
    "q": KeyBaseDescriptor(canonical: "q", category: .editing),
    "r": KeyBaseDescriptor(canonical: "r", category: .editing),
    "s": KeyBaseDescriptor(canonical: "s", category: .editing),
    "t": KeyBaseDescriptor(canonical: "t", category: .editing),
    "u": KeyBaseDescriptor(canonical: "u", category: .editing),
    "v": KeyBaseDescriptor(canonical: "v", category: .editing),
    "w": KeyBaseDescriptor(canonical: "w", category: .editing),
    "x": KeyBaseDescriptor(canonical: "x", category: .editing),
    "y": KeyBaseDescriptor(canonical: "y", category: .editing),
    "z": KeyBaseDescriptor(canonical: "z", category: .editing),
    "0": KeyBaseDescriptor(canonical: "0", category: .editing),
    "1": KeyBaseDescriptor(canonical: "1", category: .editing),
    "2": KeyBaseDescriptor(canonical: "2", category: .editing),
    "3": KeyBaseDescriptor(canonical: "3", category: .editing),
    "4": KeyBaseDescriptor(canonical: "4", category: .editing),
    "5": KeyBaseDescriptor(canonical: "5", category: .editing),
    "6": KeyBaseDescriptor(canonical: "6", category: .editing),
    "7": KeyBaseDescriptor(canonical: "7", category: .editing),
    "8": KeyBaseDescriptor(canonical: "8", category: .editing),
    "9": KeyBaseDescriptor(canonical: "9", category: .editing),
    ",": KeyBaseDescriptor(canonical: "comma", category: .editing),
    ".": KeyBaseDescriptor(canonical: "period", category: .editing),
    "/": KeyBaseDescriptor(canonical: "slash", category: .editing),
    "\\": KeyBaseDescriptor(canonical: "backslash", category: .editing),
    ";": KeyBaseDescriptor(canonical: "semicolon", category: .editing),
    "'": KeyBaseDescriptor(canonical: "quote", category: .editing),
    "`": KeyBaseDescriptor(canonical: "grave", category: .editing),
    "[": KeyBaseDescriptor(canonical: "left-bracket", category: .editing),
    "]": KeyBaseDescriptor(canonical: "right-bracket", category: .editing),
  ]

  public static func normalize(_ raw: String) -> String? {
    descriptor(for: raw)?.normalized
  }

  public static func category(for canonical: String) -> KeyCategory? {
    descriptor(for: canonical)?.category
  }

  public static func descriptor(for raw: String) -> KeyTokenDescriptor? {
    let normalizedInput =
      raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacing("+", with: "-")

    guard !normalizedInput.isEmpty else { return nil }

    let parts =
      normalizedInput
      .split(separator: "-", omittingEmptySubsequences: false)
      .map(String.init)
    guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else { return nil }

    return descriptor(for: parts, baseLengths: [2, 1])
  }

  private static func descriptor(for parts: [String], baseLengths: [Int]) -> KeyTokenDescriptor? {
    for baseLength in baseLengths where parts.count >= baseLength {
      let baseRaw = parts.suffix(baseLength).joined(separator: "-")
      guard let resolvedBase = baseDescriptor(for: baseRaw) else { continue }
      guard
        let modifiers = modifiers(
          from: parts.dropLast(baseLength),
          implicitModifiers: resolvedBase.implicitModifiers
        )
      else {
        return nil
      }

      let normalized = (modifiers.map(\.rawValue) + [resolvedBase.base.canonical]).joined(separator: "-")
      return KeyTokenDescriptor(
        normalized: normalized,
        baseToken: resolvedBase.base.canonical,
        modifiers: modifiers,
        category: category(for: resolvedBase.base, modifiers: modifiers)
      )
    }

    return nil
  }

  private static func modifiers(from parts: ArraySlice<String>, implicitModifiers: Set<KeyModifier>) -> [KeyModifier]? {
    var modifierSet = Set<KeyModifier>()
    for modifierRaw in parts {
      guard let modifier = KeyModifier.resolve(modifierRaw.lowercased()), modifierSet.insert(modifier).inserted else {
        return nil
      }
    }

    modifierSet.formUnion(implicitModifiers)
    return KeyModifier.canonicalOrder.filter { modifierSet.contains($0) }
  }

  private static func category(for base: KeyBaseDescriptor, modifiers: [KeyModifier]) -> KeyCategory {
    guard !modifiers.isEmpty else { return base.category }
    if usesControlCategory(for: modifiers) {
      return .control
    }
    return .shortcut
  }

  private static func baseDescriptor(for raw: String) -> ResolvedKeyBaseDescriptor? {
    let lowered = raw.lowercased()
    if let base = namedBaseDescriptors[lowered] {
      return ResolvedKeyBaseDescriptor(base: base, implicitModifiers: [])
    }

    if let base = singleCharacterBaseDescriptor(for: raw) {
      return base
    }

    if lowered.count >= 2,
      lowered.first == "f",
      let number = Int(lowered.dropFirst()),
      (1...12).contains(number)
    {
      return ResolvedKeyBaseDescriptor(
        base: KeyBaseDescriptor(canonical: lowered, category: .function),
        implicitModifiers: []
      )
    }

    return nil
  }

  private static func singleCharacterBaseDescriptor(for raw: String) -> ResolvedKeyBaseDescriptor? {
    guard raw.count == 1 else { return nil }

    if let character = raw.first, character.isLetter {
      let canonical = String(character).lowercased()
      guard let base = singleCharacterBaseDescriptors[canonical] else { return nil }
      let implicitModifiers: Set<KeyModifier> = character.isUppercase ? [.shift] : []
      return ResolvedKeyBaseDescriptor(base: base, implicitModifiers: implicitModifiers)
    }

    guard let base = singleCharacterBaseDescriptors[raw] else { return nil }
    return ResolvedKeyBaseDescriptor(base: base, implicitModifiers: [])
  }

  private static func usesControlCategory(for modifiers: [KeyModifier]) -> Bool {
    let modifierSet = Set(modifiers)
    return modifierSet.contains(.ctrl) && modifierSet.isSubset(of: [.ctrl, .shift])
  }
}
