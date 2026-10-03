import AppKit
import Observation

/// Connected screens keyed by CoreGraphics display UUID, refreshed on every screen-parameter
/// change so placement and the settings picker read one catalog.
@MainActor
@Observable
final class AgentIslandDisplayCatalog {
  static let shared = AgentIslandDisplayCatalog()

  private(set) var screens: [AgentIslandScreenDescriptor] = []
  private var observers: [NSObjectProtocol] = []

  init(notificationCenter: NotificationCenter = .default) {
    refresh()
    let observer = notificationCenter.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refresh()
      }
    }
    observers.append(observer)
  }

  func refresh() {
    screens = NSScreen.screens.compactMap(Self.descriptor(for:))
  }

  func descriptor(for screen: NSScreen?) -> AgentIslandScreenDescriptor? {
    guard let screen else { return nil }
    return Self.descriptor(for: screen)
  }

  private static func descriptor(for screen: NSScreen) -> AgentIslandScreenDescriptor? {
    guard
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return nil }
    let displayID = CGDirectDisplayID(number.uint32Value)
    guard let displayUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
      return nil
    }
    let id = CFUUIDCreateString(nil, displayUUID) as String
    let notchFrame = AgentIslandScreenLayout.notchFrame(
      screenFrame: screen.frame,
      safeAreaTopInset: screen.safeAreaInsets.top,
      auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
      auxiliaryTopRightArea: screen.auxiliaryTopRightArea
    )
    return AgentIslandScreenDescriptor(
      id: id,
      name: screen.localizedName,
      frame: screen.frame,
      visibleFrame: screen.visibleFrame,
      isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
      notchFrame: notchFrame
    )
  }
}
