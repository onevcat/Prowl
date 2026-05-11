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

  nonisolated static var `default`: CanvasCardDebugStyleConfiguration {
    CanvasCardDebugStyleConfiguration(
      cardBackdrop: .defaultCard,
      titleBarBackdrop: .defaultTitleBar,
      selectedCardTintOpacity: 0.08,
      selectedTitleBarTintOpacity: 0.12,
      notificationTintOpacity: 0.55,
      terminalBackgroundOpacity: nil,
      terminalBackgroundOpacityCells: nil
    )
  }

  init(
    cardBackdrop: Backdrop,
    titleBarBackdrop: Backdrop,
    selectedCardTintOpacity: Double,
    selectedTitleBarTintOpacity: Double,
    notificationTintOpacity: Double,
    terminalBackgroundOpacity: Double?,
    terminalBackgroundOpacityCells: Bool?
  ) {
    self.cardBackdrop = cardBackdrop
    self.titleBarBackdrop = titleBarBackdrop
    self.selectedCardTintOpacity = selectedCardTintOpacity
    self.selectedTitleBarTintOpacity = selectedTitleBarTintOpacity
    self.notificationTintOpacity = notificationTintOpacity
    self.terminalBackgroundOpacity = terminalBackgroundOpacity
    self.terminalBackgroundOpacityCells = terminalBackgroundOpacityCells
  }

  private enum CodingKeys: String, CodingKey {
    case cardBackdrop
    case titleBarBackdrop
    case selectedCardTintOpacity
    case selectedTitleBarTintOpacity
    case notificationTintOpacity
    case terminalBackgroundOpacity
    case terminalBackgroundOpacityCells
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
  }
}

extension CanvasCardDebugStyleConfiguration {
  var terminalOverrideSignature: String? {
    guard terminalBackgroundOpacity != nil || terminalBackgroundOpacityCells != nil else { return nil }
    return [
      terminalBackgroundOpacity.map { "background-opacity=\($0)" },
      terminalBackgroundOpacityCells.map { "background-opacity-cells=\($0)" },
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
}

@MainActor
@Observable
final class CanvasCardDebugStyleStore {
  nonisolated static let debugFileURL = URL(fileURLWithPath: "/tmp/prowl-canvas-card-debug.json")
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
  }

  func startWatching() {
    watchTask?.cancel()
    reloadIfNeeded()
    watchTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.pollInterval)
        guard !Task.isCancelled else { return }
        self?.reloadIfNeeded()
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
