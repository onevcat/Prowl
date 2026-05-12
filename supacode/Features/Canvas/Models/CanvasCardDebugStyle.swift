import Foundation
import Observation

private let canvasCardDebugStyleLogger = SupaLogger("CanvasCardDebugStyle")

nonisolated struct CanvasCardDebugStyleConfiguration: Codable, Equatable, Sendable {
  var cardBackdrop: Backdrop
  var titleBarBackdrop: Backdrop
  var selectedCardTintOpacity: Double
  var selectedTitleBarTintOpacity: Double
  var notificationTintOpacity: Double
  var terminalBackgroundOpacity: Double?
  var terminalBackgroundOpacityCells: Bool?
  var terminalCellBackgroundOpacity: Double?
  var terminalBackgroundBlur: TerminalBackgroundBlur?
  var hotReloadEnabled: Bool
  var cardGlassTintOpacity: Double
  var terminalReadabilityScrimOpacity: Double
  var terminalReadabilityScrimLightColor: HexColor?
  var terminalReadabilityScrimDarkColor: HexColor?

  nonisolated static var `default`: CanvasCardDebugStyleConfiguration {
    CanvasCardDebugStyleConfiguration(
      cardBackdrop: .defaultCard,
      titleBarBackdrop: .defaultTitleBar,
      selectedCardTintOpacity: 0.08,
      selectedTitleBarTintOpacity: 0.12,
      notificationTintOpacity: 0.55,
      terminalBackgroundOpacity: nil,
      terminalBackgroundOpacityCells: nil,
      terminalCellBackgroundOpacity: nil,
      terminalBackgroundBlur: nil,
      hotReloadEnabled: true,
      cardGlassTintOpacity: 0,
      terminalReadabilityScrimOpacity: 0,
      terminalReadabilityScrimLightColor: nil,
      terminalReadabilityScrimDarkColor: nil
    )
  }

  init(
    cardBackdrop: Backdrop,
    titleBarBackdrop: Backdrop,
    selectedCardTintOpacity: Double,
    selectedTitleBarTintOpacity: Double,
    notificationTintOpacity: Double,
    terminalBackgroundOpacity: Double?,
    terminalBackgroundOpacityCells: Bool?,
    terminalCellBackgroundOpacity: Double?,
    terminalBackgroundBlur: TerminalBackgroundBlur?,
    hotReloadEnabled: Bool,
    cardGlassTintOpacity: Double,
    terminalReadabilityScrimOpacity: Double,
    terminalReadabilityScrimLightColor: HexColor?,
    terminalReadabilityScrimDarkColor: HexColor?
  ) {
    self.cardBackdrop = cardBackdrop
    self.titleBarBackdrop = titleBarBackdrop
    self.selectedCardTintOpacity = selectedCardTintOpacity
    self.selectedTitleBarTintOpacity = selectedTitleBarTintOpacity
    self.notificationTintOpacity = notificationTintOpacity
    self.terminalBackgroundOpacity = terminalBackgroundOpacity
    self.terminalBackgroundOpacityCells = terminalBackgroundOpacityCells
    self.terminalCellBackgroundOpacity = terminalCellBackgroundOpacity
    self.terminalBackgroundBlur = terminalBackgroundBlur
    self.hotReloadEnabled = hotReloadEnabled
    self.cardGlassTintOpacity = cardGlassTintOpacity
    self.terminalReadabilityScrimOpacity = terminalReadabilityScrimOpacity
    self.terminalReadabilityScrimLightColor = terminalReadabilityScrimLightColor
    self.terminalReadabilityScrimDarkColor = terminalReadabilityScrimDarkColor
  }

  private enum CodingKeys: String, CodingKey {
    case cardBackdrop
    case titleBarBackdrop
    case selectedCardTintOpacity
    case selectedTitleBarTintOpacity
    case notificationTintOpacity
    case terminalBackgroundOpacity
    case terminalBackgroundOpacityCells
    case terminalCellBackgroundOpacity
    case terminalBackgroundBlur
    case hotReloadEnabled
    case cardGlassTintOpacity
    case terminalReadabilityScrimOpacity
    case terminalReadabilityScrimLightColor
    case terminalReadabilityScrimDarkColor
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaultStyle = CanvasCardDebugStyleConfiguration.default
    self.cardBackdrop = try container.decodeIfPresent(Backdrop.self, forKey: .cardBackdrop)
      ?? defaultStyle.cardBackdrop
    self.titleBarBackdrop = try container.decodeIfPresent(Backdrop.self, forKey: .titleBarBackdrop)
      ?? defaultStyle.titleBarBackdrop
    self.selectedCardTintOpacity = try container.decodeIfPresent(Double.self, forKey: .selectedCardTintOpacity)
      ?? defaultStyle.selectedCardTintOpacity
    self.selectedTitleBarTintOpacity =
      try container.decodeIfPresent(Double.self, forKey: .selectedTitleBarTintOpacity)
      ?? defaultStyle.selectedTitleBarTintOpacity
    self.notificationTintOpacity = try container.decodeIfPresent(Double.self, forKey: .notificationTintOpacity)
      ?? defaultStyle.notificationTintOpacity
    self.terminalBackgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .terminalBackgroundOpacity)
    self.terminalBackgroundOpacityCells = try container.decodeIfPresent(Bool.self, forKey: .terminalBackgroundOpacityCells)
    self.terminalCellBackgroundOpacity =
      try container.decodeIfPresent(Double.self, forKey: .terminalCellBackgroundOpacity)
    self.terminalBackgroundBlur = try container.decodeIfPresent(
      TerminalBackgroundBlur.self,
      forKey: .terminalBackgroundBlur
    )
    self.hotReloadEnabled = try container.decodeIfPresent(Bool.self, forKey: .hotReloadEnabled)
      ?? defaultStyle.hotReloadEnabled
    self.cardGlassTintOpacity = try container.decodeIfPresent(Double.self, forKey: .cardGlassTintOpacity)
      ?? defaultStyle.cardGlassTintOpacity
    self.terminalReadabilityScrimOpacity =
      try container.decodeIfPresent(Double.self, forKey: .terminalReadabilityScrimOpacity)
      ?? defaultStyle.terminalReadabilityScrimOpacity
    self.terminalReadabilityScrimLightColor =
      try container.decodeIfPresent(HexColor.self, forKey: .terminalReadabilityScrimLightColor)
    self.terminalReadabilityScrimDarkColor =
      try container.decodeIfPresent(HexColor.self, forKey: .terminalReadabilityScrimDarkColor)
  }
}

extension CanvasCardDebugStyleConfiguration {
  var terminalOverrideSignature: String? {
    guard
      terminalBackgroundOpacity != nil
        || terminalBackgroundOpacityCells != nil
        || terminalCellBackgroundOpacity != nil
        || terminalBackgroundBlur != nil
    else {
      return nil
    }
    return [
      terminalBackgroundOpacity.map { "background-opacity=\($0)" },
      terminalBackgroundOpacityCells.map { "background-opacity-cells=\($0)" },
      terminalCellBackgroundOpacity.map { "background-opacity-cells-alpha=\($0)" },
      terminalBackgroundBlur.map { "background-blur=\($0.rawValue)" },
    ]
    .compactMap(\.self)
    .joined(separator: "\n")
  }

  var terminalOverrideContents: String? {
    var lines: [String] = []
    if let terminalBackgroundOpacity {
      let opacity = min(max(terminalBackgroundOpacity, 0.001), 1)
      lines.append("background-opacity = \(opacity)")
    }
    if let terminalBackgroundOpacityCells {
      lines.append("background-opacity-cells = \(terminalBackgroundOpacityCells)")
    }
    if let terminalCellBackgroundOpacity {
      let opacity = min(max(terminalCellBackgroundOpacity, 0), 1)
      lines.append("background-opacity-cells-alpha = \(opacity)")
    }
    if let terminalBackgroundBlur {
      lines.append("background-blur = \(terminalBackgroundBlur.rawValue)")
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
}

extension CanvasCardDebugStyleConfiguration {
  nonisolated struct Backdrop: Codable, Equatable, Sendable {
    var style: BackdropStyle
    var opacity: Double
    var material: VisualEffectMaterial
    var blendingMode: VisualEffectBlendingMode

    nonisolated static var defaultCard: Backdrop {
      Backdrop(
        style: .clear,
        opacity: 1,
        material: .hudWindow,
        blendingMode: .behindWindow
      )
    }

    nonisolated static var defaultTitleBar: Backdrop {
      Backdrop(
        style: .bar,
        opacity: 0.9,
        material: .hudWindow,
        blendingMode: .behindWindow
      )
    }

    init(
      style: BackdropStyle,
      opacity: Double,
      material: VisualEffectMaterial,
      blendingMode: VisualEffectBlendingMode
    ) {
      self.style = style
      self.opacity = opacity
      self.material = material
      self.blendingMode = blendingMode
    }

    private enum CodingKeys: String, CodingKey {
      case style
      case opacity
      case material
      case blendingMode
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.style = try container.decodeIfPresent(BackdropStyle.self, forKey: .style) ?? .clear
      self.opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
      self.material = try container.decodeIfPresent(VisualEffectMaterial.self, forKey: .material) ?? .hudWindow
      self.blendingMode =
        try container.decodeIfPresent(VisualEffectBlendingMode.self, forKey: .blendingMode) ?? .behindWindow
    }
  }

  nonisolated enum BackdropStyle: String, Codable, Equatable, Sendable {
    case clear
    case bar
    case glassRegular
    case glassClear
    case visualEffect
  }

  nonisolated enum VisualEffectMaterial: String, Codable, Equatable, Sendable {
    case contentBackground
    case fullScreenUI
    case headerView
    case hudWindow
    case menu
    case popover
    case selection
    case sheet
    case sidebar
    case titlebar
    case toolTip
    case underPageBackground
    case underWindowBackground
    case windowBackground
  }

  nonisolated enum VisualEffectBlendingMode: String, Codable, Equatable, Sendable {
    case behindWindow
    case withinWindow
  }

  nonisolated enum TerminalBackgroundBlur: String, Codable, Equatable, Sendable {
    case off = "false"
    case on = "true"
    case macosGlassRegular = "macos-glass-regular"
    case macosGlassClear = "macos-glass-clear"
  }

  nonisolated struct HexColor: Codable, Equatable, Sendable {
    private static let fullAlphaByte: UInt8 = 255
    private static let maxByteValue: Double = 255

    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(
      red: Double,
      green: Double,
      blue: Double,
      alpha: Double = 1
    ) {
      self.red = red
      self.green = green
      self.blue = blue
      self.alpha = alpha
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      guard let parsed = Self.parse(value) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Expected #RRGGBB or #RRGGBBAA color"
        )
      }
      self = parsed
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(hexString)
    }

    private var hexString: String {
      let redByte = Self.byte(from: red)
      let greenByte = Self.byte(from: green)
      let blueByte = Self.byte(from: blue)
      let alphaByte = Self.byte(from: alpha)
      if alphaByte == Self.fullAlphaByte {
        return String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
      }
      return String(format: "#%02X%02X%02X%02X", redByte, greenByte, blueByte, alphaByte)
    }

    private static func normalizedHexString(from value: String) -> String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    }

    private static func components(from value: String) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)? {
      let hex = normalizedHexString(from: value)
      guard hex.count == 6 || hex.count == 8, let rawValue = UInt32(hex, radix: 16) else { return nil }
      if hex.count == 6 {
        return (
          UInt8((rawValue & 0xFF0000) >> 16),
          UInt8((rawValue & 0x00FF00) >> 8),
          UInt8(rawValue & 0x0000FF),
          Self.fullAlphaByte
        )
      }
      return (
        UInt8((rawValue & 0xFF000000) >> 24),
        UInt8((rawValue & 0x00FF0000) >> 16),
        UInt8((rawValue & 0x0000FF00) >> 8),
        UInt8(rawValue & 0x000000FF)
      )
    }

    private static func component(from byte: UInt8) -> Double {
      Double(byte) / Self.maxByteValue
    }

    private static func byte(from value: Double) -> Int {
      Int((min(max(value, 0), 1) * Self.maxByteValue).rounded())
    }

    private static func parse(_ value: String) -> HexColor? {
      guard let components = components(from: value) else { return nil }
      return HexColor(
        red: component(from: components.red),
        green: component(from: components.green),
        blue: component(from: components.blue),
        alpha: component(from: components.alpha)
      )
    }
  }
}

@MainActor
@Observable
final class CanvasCardDebugStyleStore {
  nonisolated static let debugFileURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".prowl-canvas-card-debug.json")
  private static let pollInterval: Duration = .milliseconds(350)

  private let fileURL: URL
  private let fileManager: FileManager
  private var watchedModificationDate: Date?
  private var watchTask: Task<Void, Never>?

  private(set) var configuration = CanvasCardDebugStyleConfiguration.default

  init(
    fileURL: URL = CanvasCardDebugStyleStore.debugFileURL,
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    reloadIfNeeded()
  }

  func startWatching() {
    watchTask?.cancel()
    reloadIfNeeded()
    guard configuration.hotReloadEnabled else { return }
    watchTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.pollInterval)
        guard !Task.isCancelled else { return }
        self?.reloadIfNeeded()
        guard self?.configuration.hotReloadEnabled == true else {
          self?.watchTask = nil
          return
        }
      }
    }
  }

  func stopWatching() {
    watchTask?.cancel()
    watchTask = nil
  }

  private func reloadIfNeeded() {
    guard let modificationDate = modificationDate() else {
      watchedModificationDate = nil
      configuration = .default
      return
    }
    guard modificationDate != watchedModificationDate else { return }
    watchedModificationDate = modificationDate
    reload()
  }

  private func reload() {
    do {
      let data = try Data(contentsOf: fileURL)
      configuration = try JSONDecoder().decode(CanvasCardDebugStyleConfiguration.self, from: data)
    } catch {
      canvasCardDebugStyleLogger.warning(
        "Failed to load Canvas card debug style from \(fileURL.path): \(error.localizedDescription)"
      )
    }
  }

  private func modificationDate() -> Date? {
    do {
      let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
      return attributes[.modificationDate] as? Date
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch CocoaError.fileNoSuchFile {
      return nil
    } catch {
      canvasCardDebugStyleLogger.warning(
        "Failed to read Canvas card debug style attributes from \(fileURL.path): \(error.localizedDescription)"
      )
      return nil
    }
  }
}
