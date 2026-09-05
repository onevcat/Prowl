import CoreGraphics
import Foundation

nonisolated struct AgentIslandFloatingPositions: Codable, Equatable, Sendable {
  private static let centeredPosition = 0.5
  private static let centeringTolerance = 0.0001

  private var positionsByDisplayID: [String: Double] = [:]

  init() {}

  var isEmpty: Bool { positionsByDisplayID.isEmpty }

  func normalizedPosition(for displayID: String) -> Double {
    Self.normalized(positionsByDisplayID[displayID] ?? Self.centeredPosition)
  }

  mutating func setNormalizedPosition(_ position: Double, for displayID: String) {
    let position = Self.normalized(position)
    if abs(position - Self.centeredPosition) < Self.centeringTolerance {
      positionsByDisplayID.removeValue(forKey: displayID)
    } else {
      positionsByDisplayID[displayID] = position
    }
  }

  private static func normalized(_ position: Double) -> Double {
    guard position.isFinite else { return centeredPosition }
    return min(max(position, 0), 1)
  }
}

nonisolated enum AgentIslandVisibilityPolicy {
  static func isVisible(isEnabled: Bool, onlyShowWithAgents: Bool, hasEntries: Bool) -> Bool {
    isEnabled && (!onlyShowWithAgents || hasEntries)
  }
}

nonisolated enum AgentIslandOpacityPolicy {
  static let defaultSilentOpacity = 0.35
  static let minimumSilentOpacity = 0.2
  static let maximumSilentOpacity = 1.0
  static let silenceDelay: Duration = .seconds(3)

  static func normalizedSilentOpacity(_ opacity: Double) -> Double {
    guard opacity.isFinite else { return defaultSilentOpacity }
    return min(max(opacity, minimumSilentOpacity), maximumSilentOpacity)
  }

  static func opacity(
    isFloating: Bool,
    isSilent: Bool,
    isRosterExpanded: Bool,
    hasAttentionEntries: Bool,
    silentOpacity: Double
  ) -> Double {
    guard isFloating, isSilent, !isRosterExpanded, !hasAttentionEntries else { return 1 }
    return normalizedSilentOpacity(silentOpacity)
  }

  static func shouldEnterSilentState(
    isFloating: Bool,
    isRosterExpanded: Bool,
    hasAttentionEntries: Bool,
    isHovering: Bool,
    isControlPresented: Bool
  ) -> Bool {
    isFloating && !isRosterExpanded && !hasAttentionEntries && !isHovering
      && !isControlPresented
  }
}

struct AgentIslandScreenDescriptor: Equatable, Identifiable {
  let id: String
  let name: String
  let frame: CGRect
  let visibleFrame: CGRect
  let isBuiltIn: Bool
  let notchFrame: CGRect?

  var hasNotch: Bool { notchFrame != nil }
  var menuBarHeight: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }
}

struct AgentIslandNotchLayout: Equatable {
  private static let minimumCompactWidth: CGFloat = 360
  /// The compact bar matches the cutout height so it ends flush with the menu bar. The floor
  /// only guards the 27pt icon cluster against an unusually short safe-area inset.
  private static let minimumCompactHeight: CGFloat = 28
  private static let minimumWingWidth: CGFloat = 120

  let cutoutSize: CGSize
  let compactWidth: CGFloat
  let compactHeight: CGFloat
  let wingWidth: CGFloat

  init(cutoutSize: CGSize) {
    let cutoutSize = CGSize(
      width: max(0, cutoutSize.width),
      height: max(0, cutoutSize.height)
    )
    let compactWidth = max(
      Self.minimumCompactWidth,
      cutoutSize.width + (Self.minimumWingWidth * 2)
    )
    self.cutoutSize = cutoutSize
    self.compactWidth = compactWidth
    compactHeight = max(Self.minimumCompactHeight, cutoutSize.height)
    wingWidth = (compactWidth - cutoutSize.width) / 2
  }
}

enum AgentIslandScreenLayout {
  static let floatingSideInset: CGFloat = 8

  static func notchFrame(
    screenFrame: CGRect,
    safeAreaTopInset: CGFloat,
    auxiliaryTopLeftArea: CGRect?,
    auxiliaryTopRightArea: CGRect?
  ) -> CGRect? {
    guard safeAreaTopInset > 0 else { return nil }
    let topBandMinY = screenFrame.maxY - safeAreaTopInset
    if let auxiliaryTopLeftArea,
      let auxiliaryTopRightArea,
      auxiliaryTopRightArea.minX > auxiliaryTopLeftArea.maxX
    {
      return CGRect(
        x: auxiliaryTopLeftArea.maxX,
        y: topBandMinY,
        width: auxiliaryTopRightArea.minX - auxiliaryTopLeftArea.maxX,
        height: safeAreaTopInset
      )
    }

    let fallbackWidth = min(220, max(180, screenFrame.width * 0.125))
    return CGRect(
      x: screenFrame.midX - (fallbackWidth / 2),
      y: topBandMinY,
      width: fallbackWidth,
      height: safeAreaTopInset
    )
  }

  static func resolve(
    preference: AgentIslandDisplayPreference,
    screens: [AgentIslandScreenDescriptor],
    mainWindowScreenID: String?,
    mainScreenID: String?
  ) -> AgentIslandScreenDescriptor? {
    if case .display(let id, _) = preference,
      let selected = screens.first(where: { $0.id == id })
    {
      return selected
    }
    if let mainWindowScreenID,
      let mainWindowScreen = screens.first(where: { $0.id == mainWindowScreenID })
    {
      return mainWindowScreen
    }
    return screens.first(where: { $0.isBuiltIn && $0.hasNotch })
      ?? mainScreenID.flatMap { id in screens.first(where: { $0.id == id }) }
      ?? screens.first
  }

  static func panelFrame(
    contentSize: CGSize,
    screen: AgentIslandScreenDescriptor,
    floatingHorizontalPosition: Double = 0.5
  ) -> CGRect {
    let top = screen.frame.maxY
    let anchorX =
      screen.notchFrame?.midX
      ?? floatingAnchorX(
        contentWidth: contentSize.width,
        normalizedPosition: floatingHorizontalPosition,
        screen: screen
      )
    return CGRect(
      x: anchorX - (contentSize.width / 2),
      y: top - contentSize.height,
      width: contentSize.width,
      height: contentSize.height
    )
  }

  private static func floatingAnchorX(
    contentWidth: CGFloat,
    normalizedPosition: Double,
    screen: AgentIslandScreenDescriptor
  ) -> CGFloat {
    let availableFrame = screen.visibleFrame.insetBy(dx: floatingSideInset, dy: 0)
    guard contentWidth < availableFrame.width else { return availableFrame.midX }

    let requestedAnchor = screen.frame.minX + (screen.frame.width * CGFloat(normalizedPosition))
    let halfWidth = contentWidth / 2
    return min(
      max(requestedAnchor, availableFrame.minX + halfWidth),
      availableFrame.maxX - halfWidth
    )
  }
}
