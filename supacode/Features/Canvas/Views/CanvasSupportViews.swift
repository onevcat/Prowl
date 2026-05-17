import AppKit
import SwiftUI

struct ActiveResize {
  let edge: CanvasCardView.CardResizeEdge
  var translation: CGSize
}

// MARK: - Scroll Container

/// Wraps SwiftUI content in an NSView whose `scrollWheel` override catches
/// unhandled scroll-wheel events and translates them into canvas-offset changes.
/// Focused terminals consume their own scroll events (they don't call super),
/// so only events over empty space or unfocused cards reach this container.
struct CanvasScrollContainer<Content: View>: NSViewRepresentable {
  @Binding var offset: CGSize
  @Binding var lastOffset: CGSize
  @Binding var scale: CGFloat
  @Binding var lastScale: CGFloat
  var isInteractionEnabled: Bool
  var onKeyDown: ((NSEvent) -> NSEvent?)?
  var canZoom: () -> Bool = { true }
  var onZoomBlocked: () -> Void = {}
  @ViewBuilder var content: Content

  func makeCoordinator() -> CanvasScrollCoordinator {
    CanvasScrollCoordinator()
  }

  func makeNSView(context: Context) -> CanvasScrollContainerView {
    let container = CanvasScrollContainerView()
    let hosting = NSHostingView(rootView: content)
    hosting.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.topAnchor.constraint(equalTo: container.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])
    container.scrollCoordinator = context.coordinator
    return container
  }

  func updateNSView(_ nsView: CanvasScrollContainerView, context: Context) {
    context.coordinator.offset = $offset
    context.coordinator.lastOffset = $lastOffset
    context.coordinator.scale = $scale
    context.coordinator.lastScale = $lastScale
    context.coordinator.onKeyDown = onKeyDown
    context.coordinator.canZoom = canZoom
    context.coordinator.onZoomBlocked = onZoomBlocked
    nsView.isInteractionEnabled = isInteractionEnabled
    if let hosting = nsView.subviews.first as? NSHostingView<Content> {
      hosting.rootView = content
    }
  }
}

class CanvasScrollCoordinator {
  var offset: Binding<CGSize> = .constant(.zero)
  var lastOffset: Binding<CGSize> = .constant(.zero)
  var scale: Binding<CGFloat> = .constant(1.0)
  var lastScale: Binding<CGFloat> = .constant(1.0)
  var onKeyDown: ((NSEvent) -> NSEvent?)?
  var canZoom: () -> Bool = { true }
  var onZoomBlocked: () -> Void = {}

  func handleScroll(deltaX: CGFloat, deltaY: CGFloat) {
    let current = offset.wrappedValue
    let newOffset = CGSize(
      width: current.width + deltaX,
      height: current.height + deltaY
    )
    offset.wrappedValue = newOffset
    lastOffset.wrappedValue = newOffset
  }

  func handleZoom(deltaY: CGFloat, anchor: CGPoint, isPrecise: Bool) {
    guard canZoom() else {
      onZoomBlocked()
      return
    }
    let result = CanvasZoomMath.zoom(
      currentScale: scale.wrappedValue,
      currentOffset: offset.wrappedValue,
      deltaY: deltaY,
      anchor: anchor,
      isPrecise: isPrecise
    )
    scale.wrappedValue = result.scale
    lastScale.wrappedValue = result.scale
    offset.wrappedValue = result.offset
    lastOffset.wrappedValue = result.offset
  }

  func setOffset(_ newOffset: CGSize) {
    offset.wrappedValue = newOffset
    lastOffset.wrappedValue = newOffset
  }

  func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    onKeyDown?(event) ?? event
  }
}

/// Pure zoom math, extracted for testability.
enum CanvasZoomMath {
  static let minScale: CGFloat = 0.25
  static let maxScale: CGFloat = 2.0

  struct Result: Equatable {
    let scale: CGFloat
    let offset: CGSize
  }

  /// Compute the new scale and offset for a Cmd+wheel zoom step.
  /// Keeps the canvas point under `anchor` fixed under the cursor:
  /// `screen = canvas * scale + offset` ⇒ `canvas = (anchor - offset) / scale`.
  static func zoom(
    currentScale: CGFloat,
    currentOffset: CGSize,
    deltaY: CGFloat,
    anchor: CGPoint,
    isPrecise: Bool
  ) -> Result {
    let sensitivity: CGFloat = isPrecise ? 0.0025 : 0.005
    let factor = exp(deltaY * sensitivity)
    let newScale = max(minScale, min(maxScale, currentScale * factor))
    guard newScale != currentScale else {
      return Result(scale: currentScale, offset: currentOffset)
    }
    let canvasX = (anchor.x - currentOffset.width) / currentScale
    let canvasY = (anchor.y - currentOffset.height) / currentScale
    let newOffset = CGSize(
      width: anchor.x - canvasX * newScale,
      height: anchor.y - canvasY * newScale
    )
    return Result(scale: newScale, offset: newOffset)
  }
}

struct CanvasOptionScrollRouter {
  static func shouldRouteToCanvas(
    modifierFlags: NSEvent.ModifierFlags,
    eventWindowNumber: Int,
    canvasWindowNumber: Int?,
    hasPreciseScrollingDeltas: Bool,
    locationInCanvas: CGPoint,
    canvasBounds: CGRect
  ) -> Bool {
    guard modifierFlags.contains(.option) else { return false }
    guard hasPreciseScrollingDeltas else { return false }
    guard let canvasWindowNumber else { return false }
    guard eventWindowNumber == canvasWindowNumber else { return false }
    return canvasBounds.contains(locationInCanvas)
  }
}

class CanvasScrollContainerView: NSView {
  var scrollCoordinator: CanvasScrollCoordinator?
  var localScrollMonitor: Any?
  var localKeyDownMonitor: Any?
  /// When false (a card is expanded), the container ignores scroll/zoom/
  /// middle-drag so the canvas can't pan or zoom behind the expanded card.
  var isInteractionEnabled = true {
    didSet {
      guard !isInteractionEnabled, oldValue else { return }
      if isMiddlePanning { endMiddlePan() }
      isPanning = false
    }
  }

  /// Whether the container is actively redirecting scroll events to canvas
  /// panning (as opposed to the brief bounce period after a gesture ends).
  var isPanning = false
  var scrollMonitor: Any?
  /// Brief delay after finger-up to wait for momentum events.
  var momentumTimer: Timer?
  /// Grace period after a pan gesture ends. A follow-up gesture that begins
  /// during this window is still treated as canvas panning, even if the
  /// cursor now sits on a focused terminal.
  var bounceTimer: Timer?

  // MARK: - Middle-click pan
  var middleButtonMonitor: Any?
  var isMiddlePanning = false
  var middlePanStartLocation: NSPoint = .zero
  var middlePanStartOffset: CGSize = .zero
  var hasPushedPanCursor = false

  override func scrollWheel(with event: NSEvent) {
    guard isInteractionEnabled else {
      if handleZoomEventIfNeeded(event) { return }
      super.scrollWheel(with: event)
      return
    }
    if handleZoomEventIfNeeded(event) { return }
    if event.phase == .began {
      startPanning()
    }
    if event.phase == .began || event.phase == .changed || event.phase == .mayBegin || event.momentumPhase != [] {
      scrollCoordinator?.handleScroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
      return
    }
    super.scrollWheel(with: event)
  }

  /// If the event is a Cmd+scroll, route it to canvas zoom and report `true`.
  /// Used by both the direct `scrollWheel` override and the local monitor so
  /// pressing Cmd mid-gesture switches behavior immediately.
  fileprivate func handleZoomEventIfNeeded(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.contains(.command), event.scrollingDeltaY != 0 else { return false }
    let viewLocation = convert(event.locationInWindow, from: nil)
    let anchor = CGPoint(x: viewLocation.x, y: bounds.height - viewLocation.y)
    scrollCoordinator?.handleZoom(
      deltaY: event.scrollingDeltaY,
      anchor: anchor,
      isPrecise: event.hasPreciseScrollingDeltas
    )
    return true
  }

  // MARK: - Pan lifecycle

  func startPanning() {
    isPanning = true
    momentumTimer?.invalidate()
    momentumTimer = nil
    bounceTimer?.invalidate()
    bounceTimer = nil
    guard scrollMonitor == nil else { return }
    installMonitor()
  }

  func installMonitor() {
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self, event.window === self.window else { return event }
      guard self.isInteractionEnabled else {
        if self.handleZoomEventIfNeeded(event) { return nil }
        return event
      }

      // Cmd toggled mid-gesture — switch to zoom for this event.
      if self.handleZoomEventIfNeeded(event) { return nil }

      // --- New gesture ------------------------------------------------
      if event.phase == .began {
        if self.isPanning {
          // Already panning (edge case). Let normal dispatch decide.
          return event
        }
        // Within the bounce window — treat as a continuation of panning.
        self.startPanning()
        self.scrollCoordinator?.handleScroll(
          deltaX: event.scrollingDeltaX,
          deltaY: event.scrollingDeltaY
        )
        return nil
      }

      // Only intercept while actively panning (not during bounce).
      guard self.isPanning else { return event }

      // --- Ongoing gesture / momentum --------------------------------
      self.momentumTimer?.invalidate()
      self.momentumTimer = nil

      if event.phase == .changed || event.momentumPhase != [] {
        self.scrollCoordinator?.handleScroll(
          deltaX: event.scrollingDeltaX,
          deltaY: event.scrollingDeltaY
        )
      }

      // Finger lifted — momentum may follow shortly.
      if event.phase == .ended || event.phase == .cancelled {
        self.momentumTimer = Timer.scheduledTimer(
          withTimeInterval: 0.1, repeats: false
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.enterBounce() }
        }
      }

      // Momentum finished.
      if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
        self.enterBounce()
      }

      return nil
    }
  }

  /// Transition from active panning to the bounce (grace) period.
  /// The monitor stays alive so a quick follow-up gesture resumes panning.
  func enterBounce() {
    isPanning = false
    momentumTimer?.invalidate()
    momentumTimer = nil
    bounceTimer?.invalidate()
    bounceTimer = Timer.scheduledTimer(
      withTimeInterval: 0.3, repeats: false
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.tearDownMonitor() }
    }
  }

  func tearDownMonitor() {
    isPanning = false
    momentumTimer?.invalidate()
    momentumTimer = nil
    bounceTimer?.invalidate()
    bounceTimer = nil
    if let monitor = scrollMonitor {
      scrollMonitor = nil
      DispatchQueue.main.async { MainActor.assumeIsolated { NSEvent.removeMonitor(monitor) } }
    }
  }

  // MARK: - Middle-click pan

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateLocalScrollMonitor()
    if window != nil {
      installMiddleButtonMonitor()
    } else {
      tearDownMiddleButtonMonitor()
    }
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      removeLocalScrollMonitor()
      removeLocalKeyDownMonitor()
      tearDownMiddleButtonMonitor()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  func updateLocalScrollMonitor() {
    guard window != nil else {
      removeLocalScrollMonitor()
      removeLocalKeyDownMonitor()
      return
    }
    if localScrollMonitor == nil {
      localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        self?.handleOptionScroll(event) ?? event
      }
    }
    if localKeyDownMonitor == nil {
      localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        self?.handleKeyDown(event) ?? event
      }
    }
  }

  func handleOptionScroll(_ event: NSEvent) -> NSEvent? {
    guard isInteractionEnabled else { return event }
    guard let window else { return event }
    let locationInCanvas = convert(event.locationInWindow, from: nil)
    guard
      CanvasOptionScrollRouter.shouldRouteToCanvas(
        modifierFlags: event.modifierFlags,
        eventWindowNumber: event.windowNumber,
        canvasWindowNumber: window.windowNumber,
        hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
        locationInCanvas: locationInCanvas,
        canvasBounds: bounds
      )
    else { return event }

    scrollCoordinator?.handleScroll(
      deltaX: event.scrollingDeltaX,
      deltaY: event.scrollingDeltaY
    )
    return nil
  }

  func removeLocalScrollMonitor() {
    if let localScrollMonitor {
      NSEvent.removeMonitor(localScrollMonitor)
      self.localScrollMonitor = nil
    }
  }

  func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    scrollCoordinator?.handleKeyDown(event) ?? event
  }

  func removeLocalKeyDownMonitor() {
    if let localKeyDownMonitor {
      NSEvent.removeMonitor(localKeyDownMonitor)
      self.localKeyDownMonitor = nil
    }
  }

  func installMiddleButtonMonitor() {
    guard middleButtonMonitor == nil else { return }
    let mask: NSEvent.EventTypeMask = [.otherMouseDown, .otherMouseDragged, .otherMouseUp]
    middleButtonMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      guard let self, event.window === self.window, event.buttonNumber == 2 else { return event }
      guard self.isInteractionEnabled else { return event }

      switch event.type {
      case .otherMouseDown:
        let location = self.convert(event.locationInWindow, from: nil)
        guard self.bounds.contains(location) else { return event }
        self.beginMiddlePan(at: event.locationInWindow)
        return nil
      case .otherMouseDragged:
        guard self.isMiddlePanning else { return event }
        self.updateMiddlePan(to: event.locationInWindow)
        return nil
      case .otherMouseUp:
        guard self.isMiddlePanning else { return event }
        self.endMiddlePan()
        return nil
      default:
        return event
      }
    }
  }

  func beginMiddlePan(at windowLocation: NSPoint) {
    isMiddlePanning = true
    middlePanStartLocation = windowLocation
    middlePanStartOffset = scrollCoordinator?.offset.wrappedValue ?? .zero
    if !hasPushedPanCursor {
      NSCursor.closedHand.push()
      hasPushedPanCursor = true
    }
  }

  func updateMiddlePan(to windowLocation: NSPoint) {
    let deltaX = windowLocation.x - middlePanStartLocation.x
    // Window Y grows upward; canvas offset Y grows downward (SwiftUI top-left).
    let deltaY = middlePanStartLocation.y - windowLocation.y
    let newOffset = CGSize(
      width: middlePanStartOffset.width + deltaX,
      height: middlePanStartOffset.height + deltaY
    )
    scrollCoordinator?.setOffset(newOffset)
  }

  func endMiddlePan() {
    isMiddlePanning = false
    if hasPushedPanCursor {
      NSCursor.pop()
      hasPushedPanCursor = false
    }
  }

  func tearDownMiddleButtonMonitor() {
    if isMiddlePanning { endMiddlePan() }
    if let monitor = middleButtonMonitor {
      middleButtonMonitor = nil
      DispatchQueue.main.async { MainActor.assumeIsolated { NSEvent.removeMonitor(monitor) } }
    }
  }

  override func removeFromSuperview() {
    tearDownMonitor()
    removeLocalScrollMonitor()
    removeLocalKeyDownMonitor()
    tearDownMiddleButtonMonitor()
    super.removeFromSuperview()
  }
}

struct CanvasTabNavigator {
  enum Direction {
    case left
    case down
    case up
    case right
  }

  struct Entry<ID: Hashable> {
    let id: ID
    let center: CGPoint
    let size: CGSize
  }

  struct NavigationTarget<ID: Hashable> {
    let id: ID
    let didWrap: Bool
  }

  static func nextID<ID: Hashable>(
    from currentID: ID,
    direction: Direction,
    entries: [Entry<ID>]
  ) -> ID? {
    nextTarget(from: currentID, direction: direction, entries: entries)?.id
  }

  static func nextTarget<ID: Hashable>(
    from currentID: ID,
    direction: Direction,
    entries: [Entry<ID>]
  ) -> NavigationTarget<ID>? {
    guard let current = entries.first(where: { $0.id == currentID }) else { return nil }
    let candidates = entries.filter { $0.id != currentID }
    guard !candidates.isEmpty else { return nil }

    let axisAligned = candidates.filter { isAxisAligned($0, with: current, direction: direction) }
    let directionalPool = axisAligned.isEmpty ? candidates : axisAligned

    let directional = directionalPool.filter {
      isDirectionalCandidate($0.center, from: current.center, direction: direction)
    }
    if let best = bestDirectionalCandidate(direction: direction, from: current.center, tabs: directional) {
      return NavigationTarget(id: best.id, didWrap: false)
    }
    guard !axisAligned.isEmpty else { return nil }
    guard let wrapped = bestWrappedCandidate(direction: direction, from: current.center, tabs: axisAligned) else {
      return nil
    }
    return NavigationTarget(id: wrapped.id, didWrap: true)
  }

  private static func isAxisAligned<ID: Hashable>(
    _ candidate: Entry<ID>,
    with current: Entry<ID>,
    direction: Direction
  ) -> Bool {
    let epsilon: CGFloat = 0.5
    let candidateFrame = frame(for: candidate)
    let currentFrame = frame(for: current)

    return switch direction {
    case .left, .right:
      overlap(
        candidateFrame.minY,
        candidateFrame.maxY,
        currentFrame.minY,
        currentFrame.maxY
      ) > epsilon
    case .up, .down:
      overlap(
        candidateFrame.minX,
        candidateFrame.maxX,
        currentFrame.minX,
        currentFrame.maxX
      ) > epsilon
    }
  }

  private static func frame<ID: Hashable>(for entry: Entry<ID>) -> CGRect {
    CGRect(
      x: entry.center.x - entry.size.width / 2,
      y: entry.center.y - entry.size.height / 2,
      width: entry.size.width,
      height: entry.size.height
    )
  }

  private static func overlap(
    _ minA: CGFloat,
    _ maxA: CGFloat,
    _ minB: CGFloat,
    _ maxB: CGFloat
  ) -> CGFloat {
    min(maxA, maxB) - max(minA, minB)
  }

  private static func isDirectionalCandidate(
    _ point: CGPoint,
    from origin: CGPoint,
    direction: Direction
  ) -> Bool {
    let epsilon: CGFloat = 0.5
    let dx = point.x - origin.x
    let dy = point.y - origin.y
    return switch direction {
    case .left:
      dx < -epsilon
    case .right:
      dx > epsilon
    case .up:
      dy < -epsilon
    case .down:
      dy > epsilon
    }
  }

  private static func bestDirectionalCandidate<ID: Hashable>(
    direction: Direction,
    from origin: CGPoint,
    tabs: [Entry<ID>]
  ) -> Entry<ID>? {
    tabs.min {
      directionalScore(for: $0.center, from: origin, direction: direction)
        < directionalScore(for: $1.center, from: origin, direction: direction)
    }
  }

  private static func directionalScore(
    for point: CGPoint,
    from origin: CGPoint,
    direction: Direction
  ) -> (primary: CGFloat, secondary: CGFloat, distance: CGFloat) {
    let dx = point.x - origin.x
    let dy = point.y - origin.y
    let distance = hypot(dx, dy)
    return switch direction {
    case .left:
      (primary: -dx, secondary: abs(dy), distance: distance)
    case .right:
      (primary: dx, secondary: abs(dy), distance: distance)
    case .up:
      (primary: -dy, secondary: abs(dx), distance: distance)
    case .down:
      (primary: dy, secondary: abs(dx), distance: distance)
    }
  }

  private static func bestWrappedCandidate<ID: Hashable>(
    direction: Direction,
    from origin: CGPoint,
    tabs: [Entry<ID>]
  ) -> Entry<ID>? {
    let wrapCoordinate: CGFloat = switch direction {
    case .left:
      tabs.map(\.center.x).max() ?? origin.x
    case .right:
      tabs.map(\.center.x).min() ?? origin.x
    case .up:
      tabs.map(\.center.y).max() ?? origin.y
    case .down:
      tabs.map(\.center.y).min() ?? origin.y
    }

    return tabs.min {
      wrappedScore(
        for: $0.center,
        from: origin,
        direction: direction,
        wrapCoordinate: wrapCoordinate
      ) < wrappedScore(
        for: $1.center,
        from: origin,
        direction: direction,
        wrapCoordinate: wrapCoordinate
      )
    }
  }

  private static func wrappedScore(
    for point: CGPoint,
    from origin: CGPoint,
    direction: Direction,
    wrapCoordinate: CGFloat
  ) -> (edgeDistance: CGFloat, crossDistance: CGFloat, distance: CGFloat) {
    let dx = point.x - origin.x
    let dy = point.y - origin.y
    let distance = hypot(dx, dy)
    return switch direction {
    case .left, .right:
      (
        edgeDistance: abs(point.x - wrapCoordinate),
        crossDistance: abs(dy),
        distance: distance
      )
    case .up, .down:
      (
        edgeDistance: abs(point.y - wrapCoordinate),
        crossDistance: abs(dx),
        distance: distance
      )
    }
  }
}

struct CanvasFocusFallbackCandidate<ID: Hashable> {
  let id: ID
  let center: CGPoint
  let size: CGSize
  let isSelected: Bool
}

func canvasFallbackFocusID<ID: Hashable>(
  focusedID: ID?,
  pendingCreatedID: ID? = nil,
  viewportSize: CGSize,
  canvasOffset: CGSize,
  canvasScale: CGFloat,
  candidates: [CanvasFocusFallbackCandidate<ID>]
) -> ID? {
  guard !candidates.isEmpty else { return nil }
  if let pendingCreatedID, candidates.contains(where: { $0.id == pendingCreatedID }) {
    return pendingCreatedID
  }
  if let focusedID, candidates.contains(where: { $0.id == focusedID }) {
    return focusedID
  }
  let selectedCandidates = candidates.filter(\.isSelected)
  if let selectedID = nearestCanvasFallbackID(
    from: selectedCandidates,
    viewportSize: viewportSize,
    canvasOffset: canvasOffset,
    canvasScale: canvasScale
  ) {
    return selectedID
  }
  return nearestCanvasFallbackID(
    from: candidates,
    viewportSize: viewportSize,
    canvasOffset: canvasOffset,
    canvasScale: canvasScale
  )
}

private func nearestCanvasFallbackID<ID: Hashable>(
  from candidates: [CanvasFocusFallbackCandidate<ID>],
  viewportSize: CGSize,
  canvasOffset: CGSize,
  canvasScale: CGFloat
) -> ID? {
  guard !candidates.isEmpty else { return nil }
  let visibleCandidates = candidates.filter {
    canvasFallbackCandidateFrame(
      for: $0,
      canvasOffset: canvasOffset,
      canvasScale: canvasScale
    ).intersects(CGRect(origin: .zero, size: viewportSize))
  }
  let candidatePool = visibleCandidates.isEmpty ? candidates : visibleCandidates
  let viewportCenter = CGPoint(
    x: viewportSize.width / 2,
    y: viewportSize.height / 2
  )
  return candidatePool.min { lhs, rhs in
    let lhsDistance = canvasFallbackDistanceToViewportCenter(
      lhs,
      viewportCenter: viewportCenter,
      canvasOffset: canvasOffset,
      canvasScale: canvasScale
    )
    let rhsDistance = canvasFallbackDistanceToViewportCenter(
      rhs,
      viewportCenter: viewportCenter,
      canvasOffset: canvasOffset,
      canvasScale: canvasScale
    )
    if lhsDistance == rhsDistance {
      return String(describing: lhs.id) < String(describing: rhs.id)
    }
    return lhsDistance < rhsDistance
  }?.id
}

private func canvasFallbackCandidateFrame<ID: Hashable>(
  for candidate: CanvasFocusFallbackCandidate<ID>,
  canvasOffset: CGSize,
  canvasScale: CGFloat
) -> CGRect {
  let screenCenter = CGPoint(
    x: candidate.center.x * canvasScale + canvasOffset.width,
    y: candidate.center.y * canvasScale + canvasOffset.height
  )
  let width = candidate.size.width * canvasScale
  let height = candidate.size.height * canvasScale
  return CGRect(
    x: screenCenter.x - width / 2,
    y: screenCenter.y - height / 2,
    width: width,
    height: height
  )
}

private func canvasFallbackDistanceToViewportCenter<ID: Hashable>(
  _ candidate: CanvasFocusFallbackCandidate<ID>,
  viewportCenter: CGPoint,
  canvasOffset: CGSize,
  canvasScale: CGFloat
) -> CGFloat {
  let screenCenter = CGPoint(
    x: candidate.center.x * canvasScale + canvasOffset.width,
    y: candidate.center.y * canvasScale + canvasOffset.height
  )
  return hypot(screenCenter.x - viewportCenter.x, screenCenter.y - viewportCenter.y)
}

func shouldShowCanvasWrapToast<ID: Hashable>(
  direction: CanvasTabNavigator.Direction,
  didWrap: Bool,
  viewportSize: CGSize,
  canvasOffset: CGSize,
  canvasScale: CGFloat,
  entries: [CanvasTabNavigator.Entry<ID>]
) -> Bool {
  guard didWrap else { return false }
  switch direction {
  case .up, .down:
    return true
  case .left, .right:
    guard viewportSize.width > 0 else { return true }
    let epsilon: CGFloat = 0.5
    let allEntriesFullyVisibleInX = entries.allSatisfy { entry in
      let frame = canvasWrapToastEntryFrame(
        entry: entry,
        canvasOffset: canvasOffset,
        canvasScale: canvasScale
      )
      return frame.minX >= -epsilon && frame.maxX <= viewportSize.width + epsilon
    }
    return !allEntriesFullyVisibleInX
  }
}

private func canvasWrapToastEntryFrame<ID: Hashable>(
  entry: CanvasTabNavigator.Entry<ID>,
  canvasOffset: CGSize,
  canvasScale: CGFloat
) -> CGRect {
  let screenCenter = CGPoint(
    x: entry.center.x * canvasScale + canvasOffset.width,
    y: entry.center.y * canvasScale + canvasOffset.height
  )
  return CGRect(
    x: screenCenter.x - (entry.size.width * canvasScale) / 2,
    y: screenCenter.y - (entry.size.height * canvasScale) / 2,
    width: entry.size.width * canvasScale,
    height: entry.size.height * canvasScale
  )
}

/// Screen-space transform for a card on canvas.
struct CardScreenGeometry {
  var size: CGSize
  var center: CGPoint
  var scale: CGFloat
}

/// An `Animatable` container that interpolates a card between its in-canvas
/// frame (`progress` 0) and the full-viewport expanded frame (`progress` 1).
///
/// Because `animatableData` is `progress`, SwiftUI re-evaluates `body` on every
/// frame of the transition, so the card's size, center, and scale advance
/// together and the terminal re-flows in lock-step with the offset/scale — a
/// true magic-move from where the card sits. This sidesteps SwiftUI's implicit
/// per-modifier interpolation, which only reached the Animatable terminal and
/// left offset/scale to snap (the "grows from the center" / "no animation" bugs).
struct AnimatedExpandableCard<Content: View>: View, Animatable {
  var progress: CGFloat
  var collapsed: CardScreenGeometry
  var expanded: CardScreenGeometry
  let titleBarHeight: CGFloat
  @ViewBuilder let content: (CGSize) -> Content

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    let fraction = max(0, min(1, progress))
    let size = CGSize(
      width: lerp(collapsed.size.width, expanded.size.width, fraction),
      height: lerp(collapsed.size.height, expanded.size.height, fraction)
    )
    let center = CGPoint(
      x: lerp(collapsed.center.x, expanded.center.x, fraction),
      y: lerp(collapsed.center.y, expanded.center.y, fraction)
    )
    let scale = lerp(collapsed.scale, expanded.scale, fraction)
    content(size)
      .scaleEffect(scale, anchor: .center)
      .offset(
        x: center.x - size.width / 2,
        y: center.y - (size.height + titleBarHeight) / 2
      )
  }

  func lerp(_ start: CGFloat, _ end: CGFloat, _ fraction: CGFloat) -> CGFloat {
    start + (end - start) * fraction
  }
}
