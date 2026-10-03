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
}

private final class CanvasViewportAnimationTimerBox {
  nonisolated(unsafe) var timer: Timer?

  deinit {
    timer?.invalidate()
  }
}

@MainActor
@Observable
final class CanvasViewportAnimator {
  struct Snapshot {
    var offset: CGSize
    var scale: CGFloat
  }

  @ObservationIgnored private let timerBox = CanvasViewportAnimationTimerBox()
  private var startSnapshot = Snapshot(offset: .zero, scale: 1)
  private var targetSnapshot = Snapshot(offset: .zero, scale: 1)
  private var startTime: CFTimeInterval = 0
  private var duration: CFTimeInterval = 0
  private var onUpdate: (@MainActor (Snapshot) -> Void)?

  func animate(
    from start: Snapshot,
    to target: Snapshot,
    duration: CFTimeInterval = 0.25,
    onUpdate: @escaping @MainActor (Snapshot) -> Void
  ) {
    cancel()
    self.startSnapshot = start
    self.targetSnapshot = target
    self.startTime = CACurrentMediaTime()
    self.duration = duration
    self.onUpdate = onUpdate

    timerBox.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  private func tick() {
    let elapsed = CACurrentMediaTime() - startTime
    let progress = min(elapsed / duration, 1.0)
    let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2

    let current = Snapshot(
      offset: CGSize(
        width: lerp(startSnapshot.offset.width, targetSnapshot.offset.width, eased),
        height: lerp(startSnapshot.offset.height, targetSnapshot.offset.height, eased)
      ),
      scale: lerp(startSnapshot.scale, targetSnapshot.scale, eased)
    )
    onUpdate?(current)

    if progress >= 1.0 {
      cancel()
    }
  }

  func cancel() {
    timerBox.timer?.invalidate()
    timerBox.timer = nil
    onUpdate = nil
  }

  private func lerp(_ start: CGFloat, _ end: CGFloat, _ fraction: CGFloat) -> CGFloat {
    start + (end - start) * fraction
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

enum CanvasViewportMath {
  struct FitResult: Equatable {
    let scale: CGFloat
    let offset: CGSize
  }

  static func fit(
    bounds: CGRect,
    viewport: CGSize,
    bottomReserve: CGFloat,
    padding: CGFloat
  ) -> FitResult? {
    guard viewport.width > 0, viewport.height > 0,
      !bounds.isNull, bounds.width > 0, bounds.height > 0,
      bounds.width.isFinite, bounds.height.isFinite
    else {
      return nil
    }

    let visibleWidth = viewport.width
    let visibleHeight = max(1, viewport.height - bottomReserve)
    let paddedWidth = max(1, bounds.width + padding * 2)
    let paddedHeight = max(1, bounds.height + padding * 2)
    let scale = max(0.25, min(1.0, min(visibleWidth / paddedWidth, visibleHeight / paddedHeight)))

    return FitResult(
      scale: scale,
      offset: CGSize(
        width: visibleWidth / 2 - bounds.midX * scale,
        height: visibleHeight / 2 - bounds.midY * scale
      )
    )
  }

  static func revealDelta(
    for cardRect: CGRect,
    viewport: CGSize,
    bottomReserve: CGFloat,
    margin: CGFloat
  ) -> CGSize {
    guard viewport.width > 0, viewport.height > 0 else { return .zero }

    let viewMinX: CGFloat = 0
    let viewMaxX = viewport.width
    let viewMinY: CGFloat = 0
    let viewMaxY = max(0, viewport.height - bottomReserve)

    var deltaX: CGFloat = 0
    var deltaY: CGFloat = 0

    if cardRect.minX < viewMinX {
      deltaX = (viewMinX + margin) - cardRect.minX
    } else if cardRect.maxX > viewMaxX {
      deltaX = (viewMaxX - margin) - cardRect.maxX
    }

    if cardRect.minY < viewMinY {
      deltaY = (viewMinY + margin) - cardRect.minY
    } else if cardRect.maxY > viewMaxY {
      deltaY = (viewMaxY - margin) - cardRect.maxY
    }

    return CGSize(width: deltaX, height: deltaY)
  }
}

class CanvasScrollContainerView: NSView {
  var scrollCoordinator: CanvasScrollCoordinator?
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
    guard isInteractionEnabled else { return false }
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
      guard self.isInteractionEnabled else { return event }

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
    if window != nil {
      installMiddleButtonMonitor()
    } else {
      tearDownMiddleButtonMonitor()
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
    tearDownMiddleButtonMonitor()
    super.removeFromSuperview()
  }
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
