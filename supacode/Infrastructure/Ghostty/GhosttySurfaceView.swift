import AppKit
import Carbon
import CoreText
import GhosttyKit
import QuartzCore
import SwiftUI

let surfaceLogger = SupaLogger("Surface")

enum GhosttyEventText {
  static func characters(for event: NSEvent) -> String? {
    guard event.type == .keyDown || event.type == .keyUp else {
      return nil
    }
    guard let characters = event.characters else { return nil }
    if characters.count == 1,
      let scalar = characters.unicodeScalars.first
    {
      if scalar.value < 0x20 {
        return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
      }
      if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
        return nil
      }
    }
    return characters
  }
}

final class GhosttySurfaceView: NSView, Identifiable {
  struct OcclusionState {
    private(set) var desired: Bool?
    private var applied: Bool?

    mutating func setDesired(_ visible: Bool) {
      desired = visible
    }

    mutating func prepareToApply(_ visible: Bool) -> Bool {
      desired = visible
      guard applied != visible else { return false }
      applied = visible
      return true
    }

    mutating func invalidateForAttachmentChange() -> Bool? {
      applied = nil
      return desired
    }

    mutating func reset() {
      desired = nil
      applied = nil
    }
  }

  private struct ScrollbarState {
    let total: UInt64
    let offset: UInt64
    let length: UInt64
  }

  struct KeyboardLayoutChangeKeyUpSuppression: Equatable {
    static let lifetime: TimeInterval = 1

    let keyCode: UInt16
    let expiresAt: TimeInterval

    init(keyCode: UInt16, timestamp: TimeInterval) {
      self.keyCode = keyCode
      expiresAt = timestamp + Self.lifetime
    }

    func suppresses(keyCode: UInt16, timestamp: TimeInterval) -> Bool {
      timestamp <= expiresAt && self.keyCode == keyCode
    }

    func isExpired(at timestamp: TimeInterval) -> Bool {
      timestamp > expiresAt
    }
  }

  final class CachedValue<T> {
    private var value: T?
    private let fetch: () -> T
    private let duration: Duration
    private var expiryTask: Task<Void, Never>?

    init(duration: Duration, fetch: @escaping () -> T) {
      self.duration = duration
      self.fetch = fetch
    }

    deinit {
      expiryTask?.cancel()
    }

    func get() -> T {
      if let value {
        return value
      }

      let fetched = fetch()
      value = fetched
      expiryTask?.cancel()
      expiryTask = Task { [weak self] in
        guard let self else { return }
        try? await ContinuousClock().sleep(for: self.duration)
        guard !Task.isCancelled else { return }
        self.value = nil
        self.expiryTask = nil
      }
      return fetched
    }
  }

  /// Environment variable that carries the pane's own UUID into every process
  /// started inside it, so an agent can address itself (`--pane "$PROWL_PANE_ID"`)
  /// without guessing from focus. Convenience identity only: the value is
  /// inherited and forgeable, so trusted attribution stays on caller-PID resolution.
  static let paneIdentityEnvironmentKey = "PROWL_PANE_ID"

  let runtime: GhosttyRuntime
  let id: UUID
  private var debugID: String {
    String(id.uuidString.prefix(8))
  }
  var debugIdentifierForLogging: String {
    debugID
  }
  let bridge: GhosttySurfaceBridge
  let launchWorkingDirectory: URL?
  /// Environment handed to the surface's shell: the caller's variables plus the pane identity.
  let launchEnvironment: [String: String]
  private(set) var surface: ghostty_surface_t?
  private var surfaceRef: GhosttyRuntime.SurfaceReference?
  private let workingDirectoryCString: UnsafeMutablePointer<CChar>?
  private let initialInputCString: UnsafeMutablePointer<CChar>?
  private let envVarCStrings: [UnsafeMutablePointer<CChar>]
  private let envVarEntries: UnsafeMutablePointer<ghostty_env_var_s>?
  private let envVarCount: Int
  private let fontSize: Float32
  private let appliesFontSizeAdjustmentMarker: Bool
  private(set) var didApplyFontSizeAdjustmentMarker = false
  private let context: ghostty_surface_context_e
  var surfaceContextForTesting: ghostty_surface_context_e {
    context
  }
  private let skipsSurfaceCreationForTesting: Bool
  private let failsSurfaceCreationForTesting: Bool
  private(set) var surfaceCreationArmed = false
  private var trackingArea: NSTrackingArea?
  private var lastBackingSize: CGSize = .zero
  var lastPerformKeyEvent: TimeInterval?
  private var currentCursor: NSCursor = .iBeam
  var focused = false
  private var detachedFocusClearTask: Task<Void, Never>?
  var markedText = NSMutableAttributedString()
  private(set) var lastEditingAt: TimeInterval?

  func recordEditingActivity() {
    lastEditingAt = ProcessInfo.processInfo.systemUptime
  }

  var keyboardLayoutChangeKeyUpSuppression: KeyboardLayoutChangeKeyUpSuppression?
  var keyTextAccumulator: [String]?
  var cellSize: CGSize = .zero
  private var lastScrollbar: ScrollbarState?
  private var occlusionState = OcclusionState()
  private var lastSurfaceFocus: Bool?
  private var eventMonitor: Any?
  private var notificationObservers: [NSObjectProtocol] = []
  var prevPressureStage: Int = 0
  private var isBackgroundOpaqueOverride = false
  lazy var cachedScreenContents = CachedValue<String>(duration: .milliseconds(500)) {
    [weak self] in
    self?.readScreenContents() ?? ""
  }
  var passwordInput: Bool = false {
    didSet {
      let input = SecureInput.shared
      let id = ObjectIdentifier(self)
      if passwordInput {
        input.setScoped(id, focused: focused)
      } else {
        input.removeScoped(id)
      }
    }
  }
  weak var scrollWrapper: GhosttySurfaceScrollView? {
    didSet {
      if let lastScrollbar {
        scrollWrapper?.updateScrollbar(
          total: lastScrollbar.total,
          offset: lastScrollbar.offset,
          length: lastScrollbar.length
        )
      }
    }
  }
  var onFocusChange: ((Bool) -> Void)?
  var onKeyInput: (() -> Void)?
  var onCommittedText: ((String) -> Void)?
  var onMirroredKey: ((MirroredTerminalKey) -> Void)?
  var onFontSizeShortcut: (() -> Void)?
  var onOcclusionAppliedForTesting: ((Bool) -> Void)?
  var attachmentStateForTesting: (() -> (hasSuperview: Bool, hasWindow: Bool))?

  var accessibilityPaneIndexHelp: String?

  private static let mouseCursorMap: [ghostty_action_mouse_shape_e: NSCursor] = [
    GHOSTTY_MOUSE_SHAPE_DEFAULT: .arrow,
    GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam,
    GHOSTTY_MOUSE_SHAPE_GRAB: .openHand,
    GHOSTTY_MOUSE_SHAPE_GRABBING: .closedHand,
    GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand,
    GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: .iBeamCursorForVerticalLayout,
    GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: .contextualMenu,
    GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair,
    GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: .operationNotAllowed,
  ]

  private static let mouseResizeLeftRightShapes: Set<ghostty_action_mouse_shape_e> = [
    GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
    GHOSTTY_MOUSE_SHAPE_W_RESIZE,
    GHOSTTY_MOUSE_SHAPE_E_RESIZE,
    GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
  ]

  private static let mouseResizeUpDownShapes: Set<ghostty_action_mouse_shape_e> = [
    GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
    GHOSTTY_MOUSE_SHAPE_N_RESIZE,
    GHOSTTY_MOUSE_SHAPE_S_RESIZE,
    GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
  ]
  static let dropTypes: Set<NSPasteboard.PasteboardType> = [
    .string,
    .fileURL,
    .URL,
  ]

  static func normalizedWorkingDirectoryPath(_ path: String) -> String {
    var normalized = path
    while normalized.count > 1 && normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }

  static func accessibilityLine(for index: Int, in content: String) -> Int {
    let clampedIndex = min(max(index, 0), content.count)
    let prefix = String(content.prefix(clampedIndex))
    return max(0, prefix.components(separatedBy: .newlines).count - 1)
  }

  static func accessibilityString(for range: NSRange, in content: String) -> String? {
    guard let swiftRange = Range(range, in: content) else { return nil }
    return String(content[swiftRange])
  }

  static func stringFromGhosttyText(pointer: UnsafePointer<CChar>?, length: UInt) -> String {
    guard let pointer, length > 0, length <= UInt(Int.max) else { return "" }
    let buffer = UnsafeRawBufferPointer(start: pointer, count: Int(length))
    return String(bytes: buffer, encoding: .utf8) ?? ""
  }

  static func string(from text: ghostty_text_s) -> String {
    stringFromGhosttyText(pointer: text.text, length: text.text_len)
  }

  override var acceptsFirstResponder: Bool { true }

  var mirrorGrid: (columns: UInt32, rows: UInt32)?
  private var commandCString: UnsafeMutablePointer<CChar>?

  init(
    runtime: GhosttyRuntime,
    workingDirectory: URL?,
    initialInput: String? = nil,
    fontSize: Float32? = nil,
    context: ghostty_surface_context_e,
    environment: [String: String] = [:],
    command: String? = nil,
    skipsSurfaceCreationForTesting: Bool = false,
    failsSurfaceCreationForTesting: Bool = false,
    defersSurfaceCreation: Bool = false
  ) {
    let id = UUID()
    self.id = id
    self.runtime = runtime
    self.bridge = GhosttySurfaceBridge()
    self.fontSize = fontSize ?? 0
    self.appliesFontSizeAdjustmentMarker = fontSize != nil
    self.context = context
    commandCString = command.flatMap { strdup($0) }
    self.skipsSurfaceCreationForTesting = skipsSurfaceCreationForTesting
    self.failsSurfaceCreationForTesting = failsSurfaceCreationForTesting
    if let workingDirectory {
      let path = Self.normalizedWorkingDirectoryPath(
        workingDirectory.path(percentEncoded: false)
      )
      launchWorkingDirectory = URL(fileURLWithPath: path, isDirectory: true)
      workingDirectoryCString = path.withCString { strdup($0) }
    } else {
      launchWorkingDirectory = nil
      workingDirectoryCString = nil
    }
    if let initialInput {
      initialInputCString = initialInput.withCString { strdup($0) }
    } else {
      initialInputCString = nil
    }
    var launchEnvironment = environment
    launchEnvironment[Self.paneIdentityEnvironmentKey] = id.uuidString
    self.launchEnvironment = launchEnvironment
    let sortedEnv = launchEnvironment.sorted { $0.key < $1.key }
    var allocatedStrings: [UnsafeMutablePointer<CChar>] = []
    allocatedStrings.reserveCapacity(sortedEnv.count * 2)
    for (key, value) in sortedEnv {
      guard let keyPtr = key.withCString({ strdup($0) }),
        let valuePtr = value.withCString({ strdup($0) })
      else { continue }
      allocatedStrings.append(keyPtr)
      allocatedStrings.append(valuePtr)
    }
    envVarCStrings = allocatedStrings
    let pairCount = allocatedStrings.count / 2
    if pairCount > 0 {
      let entries = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: pairCount)
      for index in 0..<pairCount {
        entries[index] = ghostty_env_var_s(
          key: UnsafePointer(allocatedStrings[index * 2]),
          value: UnsafePointer(allocatedStrings[index * 2 + 1])
        )
      }
      envVarEntries = entries
      envVarCount = pairCount
    } else {
      envVarEntries = nil
      envVarCount = 0
    }
    super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    wantsLayer = true
    bridge.surfaceView = self
    if !skipsSurfaceCreationForTesting, !defersSurfaceCreation {
      _ = armSurfaceCreation()
    }
    registerForDraggedTypes(Array(Self.dropTypes))

    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown, .flagsChanged]) {
      [weak self] event in
      self?.localEventHandler(event)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  isolated deinit {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
    }
    clearNotificationObservers()
    let id = ObjectIdentifier(self)
    MainActor.assumeIsolated {
      SecureInput.shared.removeScoped(id)
    }
    closeSurface()
    if let workingDirectoryCString {
      free(workingDirectoryCString)
    }
    if let commandCString { free(commandCString) }
    if let initialInputCString {
      free(initialInputCString)
    }
    if let envVarEntries {
      envVarEntries.deallocate()
    }
    for pointer in envVarCStrings {
      free(pointer)
    }
  }

  @discardableResult
  func armSurfaceCreation() -> Bool {
    guard !surfaceCreationArmed else { return true }
    surfaceCreationArmed = true
    guard !skipsSurfaceCreationForTesting else { return true }
    guard !failsSurfaceCreationForTesting else {
      surfaceCreationArmed = false
      return false
    }
    createSurface()
    guard let surface else {
      surfaceCreationArmed = false
      return false
    }
    surfaceRef = runtime.registerSurface(surface)
    // This no-op marks the native surface as font-size adjusted so a config
    // reload cannot reset an inherited/preferred size. It must run post-create.
    if appliesFontSizeAdjustmentMarker {
      performBindingAction("increase_font_size:0")
      didApplyFontSizeAdjustmentMarker = true
    }
    return true
  }

  func closeSurface() {
    clearNotificationObservers()
    if let surface {
      if let surfaceRef {
        runtime.unregisterSurface(surfaceRef)
        self.surfaceRef = nil
      }
      ghostty_surface_free(surface)
      self.surface = nil
      bridge.surface = nil
      occlusionState.reset()
      lastSurfaceFocus = nil
    }
  }

  private func updateScreenObservers() {
    clearNotificationObservers()
    guard let window else { return }
    let center = NotificationCenter.default
    notificationObservers.append(
      center.addObserver(
        forName: NSWindow.didChangeScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.windowDidChangeScreen()
        }
      })
    notificationObservers.append(
      center.addObserver(
        forName: NSWindow.didEnterFullScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.applyWindowBackgroundAppearance()
        }
      })
    notificationObservers.append(
      center.addObserver(
        forName: NSWindow.didExitFullScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.applyWindowBackgroundAppearance()
        }
      })
    notificationObservers.append(
      center.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.applyWindowBackgroundAppearance()
        }
      })
    notificationObservers.append(
      center.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.applyWindowBackgroundAppearance()
        }
      })
    notificationObservers.append(
      center.addObserver(
        forName: .ghosttyRuntimeConfigDidChange,
        object: runtime,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.applyWindowBackgroundAppearance()
        }
      })
  }

  private func windowDidChangeScreen() {
    guard let surface, let screen = window?.screen else { return }
    let displayID =
      screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    ghostty_surface_set_display_id(surface, displayID)
    DispatchQueue.main.async { [weak self] in
      self?.viewDidChangeBackingProperties()
    }
  }

  private func clearNotificationObservers() {
    let center = NotificationCenter.default
    for observer in notificationObservers {
      center.removeObserver(observer)
    }
    notificationObservers.removeAll()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      // SwiftUI can temporarily detach a pane while rebuilding split/zoom
      // layout — or when another SwiftUI subtree (e.g. Shelf) takes over
      // hosting the same surface. Clearing the focused bit immediately
      // here is wrong for the re-attach case: AppKit silently resigns the
      // surface without a call path we can observe, and same-window
      // re-attach does not trigger `becomeFirstResponder`, so the focused
      // bit never recovers. Delay the clear so a prompt re-attach
      // cancels it; only when the surface truly stays detached past the
      // grace window do we flip the bit.
      detachedFocusClearTask?.cancel()
      detachedFocusClearTask = Task { @MainActor [weak self] in
        try? await ContinuousClock().sleep(for: .milliseconds(150))
        guard !Task.isCancelled, let self, self.window == nil else { return }
        focusDidChange(false)
      }
    } else {
      detachedFocusClearTask?.cancel()
      detachedFocusClearTask = nil
    }
    updateScreenObservers()
    updateContentScale()
    updateSurfaceSize()
    applyWindowBackgroundAppearance()
    handleAttachmentChange()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    handleAttachmentChange()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    if let window {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer?.contentsScale = window.backingScaleFactor
      CATransaction.commit()
    }
    updateContentScale()
    updateSurfaceSize()
  }

  override func layout() {
    super.layout()
    updateSurfaceSize()
  }

  override func updateTrackingAreas() {
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: currentCursor)
  }

  func toggleBackgroundOpacity() {
    guard runtime.backgroundOpacity() < 1 else { return }
    isBackgroundOpaqueOverride.toggle()
    applyWindowBackgroundAppearance()
  }

  private func applyWindowBackgroundAppearance() {
    guard let window, window.isVisible else { return }
    let opacity = runtime.backgroundOpacity()
    window.titlebarAppearsTransparent = true
    if !isBackgroundOpaqueOverride, !window.styleMask.contains(.fullScreen), opacity < 1 {
      window.isOpaque = false
      let isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      window.backgroundColor = GhosttyRuntime.chromeBackgroundColor(for: isDark ? .black : .white)
      if let app = runtime.app {
        ghostty_set_window_background_blur(
          app,
          Unmanaged.passUnretained(window).toOpaque()
        )
      }
      return
    }
    window.isOpaque = true
    window.backgroundColor = runtime.backgroundColor().withAlphaComponent(1)
  }

  func focusDidChange(_ focused: Bool) {
    guard surface != nil else { return }
    guard self.focused != focused else { return }
    // Retained as the single diagnostic entry point for focus regressions.
    // Filter `make log-stream | grep '\[ShelfFocus\] focusDidChange'` to
    // trace every focused-bit transition across the app.
    SupaLogger("SurfaceFocus").info(
      "[ShelfFocus] focusDidChange surface=\(debugID) \(self.focused) -> \(focused)"
    )
    self.focused = focused
    if focused {
      bridge.state.bellCount = 0
    }
    setSurfaceFocus(focused)
    onFocusChange?(focused)
    if passwordInput {
      SecureInput.shared.setScoped(ObjectIdentifier(self), focused: focused)
    }
  }

  func updateSurfaceSize() {
    resumeDeferredOcclusionIfNeeded()
    guard let surface else { return }
    if let grid = mirrorGrid {
      let size = ghostty_surface_size(surface)
      if size.cell_width_px > 0, size.cell_height_px > 0 {
        ghostty_surface_set_size(surface, grid.columns * size.cell_width_px, grid.rows * size.cell_height_px)
      }
      return
    }
    // When pinnedSize is set (canvas mode), convertToBacking() includes the
    // .scaleEffect() layer transform, producing scale-dependent backing sizes.
    // Use the pinned size with the window's raw backing scale factor instead.
    let backingSize: CGSize
    if let pinnedSize = scrollWrapper?.pinnedSize {
      let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
      backingSize = CGSize(width: pinnedSize.width * scale, height: pinnedSize.height * scale)
    } else {
      backingSize = convertToBacking(bounds.size)
    }
    if backingSize == lastBackingSize {
      return
    }
    lastBackingSize = backingSize
    let width = UInt32(max(1, Int(backingSize.width.rounded(.down))))
    let height = UInt32(max(1, Int(backingSize.height.rounded(.down))))
    let currentSize = ghostty_surface_size(surface)
    guard currentSize.cell_width_px > 0, currentSize.cell_height_px > 0 else {
      ghostty_surface_set_size(surface, width, height)
      return
    }
    let columns = Int(width) / Int(currentSize.cell_width_px)
    let rows = Int(height) / Int(currentSize.cell_height_px)
    guard columns >= 5, rows >= 2 else { return }
    ghostty_surface_set_size(surface, width, height)
  }

  func updateCellSize(width: UInt32, height: UInt32) {
    cellSize = CGSize(width: CGFloat(width), height: CGFloat(height))
    scrollWrapper?.updateSurfaceSize()
  }

  func updateScrollbar(total: UInt64, offset: UInt64, length: UInt64) {
    lastScrollbar = ScrollbarState(total: total, offset: offset, length: length)
    scrollWrapper?.updateScrollbar(total: total, offset: offset, length: length)
  }

  func currentCellSize() -> CGSize {
    cellSize
  }

  func shouldShowScrollbar() -> Bool {
    runtime.shouldShowScrollbar()
  }

  func scrollbarAppearanceName() -> NSAppearance.Name {
    runtime.scrollbarAppearanceName()
  }

  func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
    let newCursor = cursor(for: shape)
    guard let newCursor else { return }
    guard newCursor != currentCursor else { return }
    currentCursor = newCursor
    window?.invalidateCursorRects(for: self)
  }

  private func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor? {
    if let cursor = Self.mouseCursorMap[shape] {
      return cursor
    }
    if Self.mouseResizeLeftRightShapes.contains(shape) {
      return .resizeLeftRight
    }
    if Self.mouseResizeUpDownShapes.contains(shape) {
      return .resizeUpDown
    }
    return nil
  }

  func setMouseVisibility(_ visible: Bool) {
    NSCursor.setHiddenUntilMouseMoves(!visible)
  }

  private func createSurface() {
    guard let app = runtime.app else { return }
    var config = ghostty_surface_config_new()
    config.userdata = Unmanaged.passUnretained(bridge).toOpaque()
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(
        nsview: Unmanaged.passUnretained(self).toOpaque()
      ))
    config.scale_factor = backingScaleFactor()
    config.font_size = fontSize
    config.working_directory = workingDirectoryCString.map { UnsafePointer($0) }
    config.initial_input = initialInputCString.map { UnsafePointer($0) }
    config.command = commandCString.map { UnsafePointer($0) }
    config.context = context
    if let envVarEntries, envVarCount > 0 {
      config.env_vars = envVarEntries
      config.env_var_count = envVarCount
    }
    surface = ghostty_surface_new(app, &config)
    bridge.surface = surface
    occlusionState.reset()
    lastSurfaceFocus = nil
    // A freshly created Ghostty surface defaults to focused (blinking cursor).
    // Sync it to our Swift-side `focused` flag so background/restored surfaces
    // that were never explicitly focused don't blink. `focusDidChange(false)`
    // would no-op here (self.focused already false), so push the state directly.
    setSurfaceFocus(focused)
    updateSurfaceSize()
  }

  private func updateContentScale() {
    guard let surface else { return }
    let scale = backingScaleFactor()
    ghostty_surface_set_content_scale(surface, scale, scale)
  }

  private func backingScaleFactor() -> Double {
    if let window {
      return window.backingScaleFactor
    }
    if let screen = NSScreen.main {
      return screen.backingScaleFactor
    }
    return 2.0
  }

  func setOcclusion(_ visible: Bool) {
    guard let surface else {
      guard skipsSurfaceCreationForTesting else { return }
      // Occluding (pausing render) is always safe, even without a view
      // hierarchy. This handles restored surfaces that haven't been attached
      // to a window yet.
      if !visible {
        guard occlusionState.prepareToApply(false) else { return }
        onOcclusionAppliedForTesting?(false)
        return
      }
      guard isReadyToApplyOcclusion else {
        if occlusionState.desired != visible {
          surfaceLogger.info(
            "[CanvasExit] deferOcclusion surface=\(debugID) desired=\(visible) "
              + "attached=\(hasAttachedSuperview) window=\(hasAttachedWindow)"
          )
        }
        occlusionState.setDesired(visible)
        return
      }
      guard occlusionState.prepareToApply(visible) else { return }
      onOcclusionAppliedForTesting?(visible)
      return
    }
    // Occluding (pausing render) is always safe, even without a view
    // hierarchy. This stops restored surfaces from spinning the GPU when
    // they are not displayed.
    if !visible {
      guard occlusionState.prepareToApply(false) else { return }
      onOcclusionAppliedForTesting?(false)
      ghostty_surface_set_occlusion(surface, false)
      return
    }
    guard isReadyToApplyOcclusion else {
      if occlusionState.desired != visible {
        surfaceLogger.info(
          "[CanvasExit] deferOcclusion surface=\(debugID) desired=\(visible) "
            + "attached=\(hasAttachedSuperview) window=\(hasAttachedWindow)"
        )
      }
      occlusionState.setDesired(visible)
      return
    }
    guard occlusionState.prepareToApply(visible) else { return }
    onOcclusionAppliedForTesting?(visible)
    ghostty_surface_set_occlusion(surface, visible)
  }

  private func handleAttachmentChange() {
    // Re-parenting can temporarily detach the Metal layer from the visible
    // tree and pause Ghostty's renderer. Invalidate the applied cache so the
    // currently desired occlusion value is sent again after reattachment.
    _ = occlusionState.invalidateForAttachmentChange()
    if superview == nil {
      DispatchQueue.main.async { [weak self] in
        self?.scrollWrapper?.ensureSurfaceAttached()
      }
    }
    guard isReadyToApplyOcclusion else { return }
    DispatchQueue.main.async { [weak self] in
      self?.reapplyOcclusionIfNeeded()
    }
  }

  func handleAttachmentChangeForTesting() {
    handleAttachmentChange()
  }

  func resumeDeferredOcclusionIfNeededForTesting() {
    resumeDeferredOcclusionIfNeeded()
  }

  private func resumeDeferredOcclusionIfNeeded() {
    guard isReadyToApplyOcclusion else { return }
    reapplyOcclusionIfNeeded()
  }

  private func reapplyOcclusionIfNeeded() {
    guard isReadyToApplyOcclusion, let desired = occlusionState.desired else { return }
    setOcclusion(desired)
  }

  private var isReadyToApplyOcclusion: Bool {
    hasAttachedSuperview && hasAttachedWindow
  }

  private var hasAttachedSuperview: Bool {
    attachmentStateForTesting?().hasSuperview ?? (superview != nil)
  }

  private var hasAttachedWindow: Bool {
    attachmentStateForTesting?().hasWindow ?? (window != nil)
  }

  private func setSurfaceFocus(_ focused: Bool) {
    guard let surface else { return }
    if lastSurfaceFocus == focused {
      return
    }
    lastSurfaceFocus = focused
    ghostty_surface_set_focus(surface, focused)
  }

  func requestFocus() {
    Self.moveFocus(to: self)
  }

  static func moveFocus(
    to view: GhosttySurfaceView,
    from previous: GhosttySurfaceView? = nil,
    delay: TimeInterval? = nil
  ) {
    let maxDelay: TimeInterval = 0.5
    let currentDelay = delay ?? 0
    guard currentDelay < maxDelay else { return }
    let nextDelay: TimeInterval = if let delay { delay * 2 } else { 0.05 }
    Task { @MainActor in
      if let delay {
        try? await ContinuousClock().sleep(for: .seconds(delay))
      }
      guard let window = view.window else {
        moveFocus(to: view, from: previous, delay: nextDelay)
        return
      }
      if let previous, previous !== view {
        _ = previous.resignFirstResponder()
      }
      window.makeFirstResponder(view)
    }
  }
}
