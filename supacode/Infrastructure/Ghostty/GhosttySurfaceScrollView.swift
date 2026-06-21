import AppKit
import GhosttyKit

private let surfaceScrollLogger = SupaLogger("SurfaceScroll")

final class GhosttySurfaceScrollView: NSView {
  enum HostKind: String {
    case terminal
    case canvas
  }

  private struct ScrollbarState {
    let total: UInt64
    let offset: UInt64
    let length: UInt64
  }

  private let scrollView: NSScrollView
  private let documentView: NSView
  private let surfaceView: GhosttySurfaceView
  let hostKind: HostKind
  private let debugID = String(UUID().uuidString.prefix(8))
  var debugIdentifier: String {
    debugID
  }
  private var observers: [NSObjectProtocol] = []

  private var isLiveScrolling = false
  private var isProgrammaticScrollChange = false
  private var isUserScrolledBack = false
  private var lastScrollBackTraceState: Bool?
  private var lastScrollbarTraceAt: TimeInterval = 0
  private var lastLiveScrollTraceAt: TimeInterval = 0
  private var lastSentRow: Int?
  private var scrollbar: ScrollbarState?
  private(set) var isCanvasMaxModeActive = false

  /// When set, the surface renders at this fixed size regardless of the hosting
  /// view's bounds. Used in canvas mode to prevent `.scaleEffect()` from causing
  /// terminal reflow.
  var pinnedSize: CGSize?

  init(surfaceView: GhosttySurfaceView, hostKind: HostKind) {
    self.surfaceView = surfaceView
    self.hostKind = hostKind
    scrollView = NSScrollView()
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = false
    scrollView.usesPredominantAxisScrolling = true
    scrollView.scrollerStyle = .overlay
    scrollView.drawsBackground = false
    scrollView.contentView.clipsToBounds = false
    documentView = NSView(frame: .zero)
    scrollView.documentView = documentView
    documentView.addSubview(surfaceView)
    super.init(frame: .zero)
    addSubview(scrollView)
    surfaceView.scrollWrapper = self
    refreshAppearance()

    scrollView.contentView.postsBoundsChangedNotifications = true
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: scrollView.contentView,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.handleScrollChange()
        }
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSScrollView.willStartLiveScrollNotification,
        object: scrollView,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.traceWrapperScroll("willStartLiveScroll")
          self?.isLiveScrolling = true
        }
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSScrollView.didEndLiveScrollNotification,
        object: scrollView,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.traceWrapperScroll("didEndLiveScroll")
          self?.isLiveScrolling = false
          self?.updateScrollBackState()
        }
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSScrollView.didLiveScrollNotification,
        object: scrollView,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.handleLiveScroll()
        }
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSScroller.preferredScrollerStyleDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.handleScrollerStyleChange()
        }
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: .ghosttyRuntimeConfigDidChange,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.refreshAppearance()
        }
      })
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  isolated deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  override func layout() {
    super.layout()
    ensureSurfaceAttached()
    let effectiveSize = pinnedSize ?? bounds.size
    scrollView.frame = CGRect(origin: .zero, size: effectiveSize)
    surfaceView.frame.size = effectiveSize
    documentView.frame.size.width = effectiveSize.width
    synchronizeScrollView()
    synchronizeSurfaceView()
    surfaceView.updateSurfaceSize()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    ensureSurfaceAttached()
  }

  func updateDiagnosticContext(isCanvasMaxModeActive: Bool) {
    guard self.isCanvasMaxModeActive != isCanvasMaxModeActive else { return }
    self.isCanvasMaxModeActive = isCanvasMaxModeActive
    surfaceScrollLogger.diagnostic(
      "[ScrollTrace] diagnosticContext wrapper=\(debugID) host=\(hostKind.rawValue) "
        + "surface=\(surfaceView.debugIdentifierForLogging) maxMode=\(isCanvasMaxModeActive)"
    )
  }

  func updateHostedSurface(pinnedSize newPinnedSize: CGSize?) {
    let pinnedSizeChanged = pinnedSize != newPinnedSize
    if pinnedSizeChanged {
      surfaceScrollLogger.diagnostic(
        "[ScrollTrace] updateHostedSurface wrapper=\(debugID) host=\(hostKind.rawValue) "
          + "maxMode=\(isCanvasMaxModeActive) "
          + "surface=\(surfaceView.debugIdentifierForLogging) "
          + "pinned=\(Self.sizeDescription(pinnedSize)) -> \(Self.sizeDescription(newPinnedSize)) "
          + "window=\(window != nil)"
      )
    }
    pinnedSize = newPinnedSize

    let wasAttached = isSurfaceAttachedToDocumentView
    switch hostKind {
    case .canvas:
      if !wasAttached {
        surfaceView.removeFromSuperview()
        documentView.addSubview(surfaceView)
      }
    case .terminal:
      ensureSurfaceAttached(requiresLiveHost: false)
    }

    let isAttached = isSurfaceAttachedToDocumentView
    let needsSurfaceReattachment = !wasAttached && isAttached
    let needsWrapperUpdate = isAttached && surfaceView.scrollWrapper !== self
    if needsWrapperUpdate {
      surfaceScrollLogger.diagnostic(
        "[ScrollTrace] updateHostedSurface wrapperRebind wrapper=\(debugID) host=\(hostKind.rawValue) "
          + "maxMode=\(isCanvasMaxModeActive) "
          + "surface=\(surfaceView.debugIdentifierForLogging)"
      )
      surfaceView.scrollWrapper = self
    }

    guard pinnedSizeChanged || needsSurfaceReattachment || needsWrapperUpdate else { return }
    needsLayout = true
    surfaceView.needsLayout = true
    surfaceView.needsDisplay = true
    layoutSubtreeIfNeeded()
    surfaceView.updateSurfaceSize()
  }

  func updateSurfaceSize() {
    surfaceView.updateSurfaceSize()
    needsLayout = true
  }

  func applyCanvasDebugStyle(
    _ style: CanvasCardDebugStyleConfiguration?,
    configReloadGeneration: Int
  ) {
    surfaceView.applyCanvasDebugTerminalStyle(
      hostKind == .canvas ? style : nil,
      configReloadGeneration: configReloadGeneration
    )
  }

  var isSurfaceAttachedToDocumentView: Bool {
    surfaceView.superview === documentView
  }

  func ensureSurfaceAttached(requiresLiveHost: Bool = true) {
    guard hostKind == .terminal else { return }
    if requiresLiveHost {
      guard superview != nil || window != nil else { return }
    }
    guard !isSurfaceAttachedToDocumentView else { return }
    // Only adopt an orphaned surface; never steal it from a live host such as Canvas.
    guard surfaceView.superview == nil else { return }
    surfaceLogger.info(
      "[CanvasExit] hostReattach wrapper=\(debugID) host=\(hostKind.rawValue) "
        + "surface=\(surfaceView.debugIdentifierForLogging) "
        + "currentSuperview=\(String(describing: surfaceView.superview)) "
        + "wrapperWindow=\(window != nil)"
    )
    documentView.addSubview(surfaceView)
    surfaceView.scrollWrapper = self
    surfaceLogger.info(
      "[CanvasExit] hostReattachComplete wrapper=\(debugID) host=\(hostKind.rawValue) "
        + "surface=\(surfaceView.debugIdentifierForLogging) "
        + "superview=\(surfaceView.superview != nil) "
        + "window=\(surfaceView.window != nil) "
        + "bounds=\(Int(surfaceView.bounds.width))x\(Int(surfaceView.bounds.height))"
    )
  }

  func updateScrollbar(total: UInt64, offset: UInt64, length: UInt64) {
    traceScrollbarUpdate(total: total, offset: offset, length: length)
    scrollbar = ScrollbarState(total: total, offset: offset, length: length)
    synchronizeScrollView()
  }

  func refreshAppearance() {
    scrollView.hasVerticalScroller = surfaceView.shouldShowScrollbar()
    scrollView.appearance = NSAppearance(named: surfaceView.scrollbarAppearanceName())
    scrollView.scrollerStyle = .overlay
    updateTrackingAreas()
  }

  private func handleScrollChange() {
    synchronizeSurfaceView()
    guard !isProgrammaticScrollChange else {
      return
    }
    updateScrollBackState()
  }

  private func handleScrollerStyleChange() {
    refreshAppearance()
    surfaceView.updateSurfaceSize()
  }

  private func synchronizeSurfaceView() {
    let visibleRect = scrollView.contentView.documentVisibleRect
    surfaceView.frame.origin = visibleRect.origin
  }

  private func synchronizeScrollView() {
    documentView.frame.size.height = documentHeight()
    if !isLiveScrolling && !isUserScrolledBack {
      let cellHeight = surfaceView.currentCellSize().height
      if cellHeight > 0, let scrollbar {
        let targetY =
          CGFloat(scrollbar.total - scrollbar.offset - scrollbar.length) * cellHeight
        isProgrammaticScrollChange = true
        defer { isProgrammaticScrollChange = false }
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
        lastSentRow = Int(scrollbar.offset)
      }
    }
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  /// Tracks whether the user intentionally moved away from the live bottom of
  /// the terminal. While this is true we keep the viewport fixed so incoming
  /// output cannot yank scrollback out from under the user.
  private func updateScrollBackState() {
    let cellHeight = surfaceView.currentCellSize().height
    guard cellHeight > 0 else {
      isUserScrolledBack = false
      return
    }

    let visibleRect = scrollView.contentView.documentVisibleRect
    let distanceFromBottom = max(0, documentView.frame.height - visibleRect.maxY)
    isUserScrolledBack = distanceFromBottom > cellHeight / 2
    if lastScrollBackTraceState != isUserScrolledBack {
      lastScrollBackTraceState = isUserScrolledBack
      surfaceScrollLogger.diagnostic(
        "[ScrollTrace] scrollBackState wrapper=\(debugID) host=\(hostKind.rawValue) "
          + "maxMode=\(isCanvasMaxModeActive) "
          + "surface=\(surfaceView.debugIdentifierForLogging) isUserScrolledBack=\(isUserScrolledBack) "
          + "distanceFromBottom=\(Int(distanceFromBottom)) cellHeight=\(Int(cellHeight))"
      )
    }
  }

  private func handleLiveScroll() {
    let cellHeight = surfaceView.currentCellSize().height
    guard cellHeight > 0 else { return }
    let visibleRect = scrollView.contentView.documentVisibleRect
    let documentHeight = documentView.frame.height
    let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height
    let row = Int(scrollOffset / cellHeight)
    guard row != lastSentRow else { return }
    lastSentRow = row
    traceLiveScroll(row: row, visibleRect: visibleRect)
    surfaceView.performBindingAction("scroll_to_row:\(row)")
  }

  private func documentHeight() -> CGFloat {
    let contentHeight = scrollView.contentSize.height
    let cellHeight = surfaceView.currentCellSize().height
    if cellHeight > 0, let scrollbar {
      let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
      let padding = contentHeight - (CGFloat(scrollbar.length) * cellHeight)
      return documentGridHeight + padding
    }
    return contentHeight
  }

  private func traceScrollbarUpdate(total: UInt64, offset: UInt64, length: UInt64) {
    let now = ProcessInfo.processInfo.systemUptime
    let totalOrLengthChanged = scrollbar?.total != total || scrollbar?.length != length
    guard totalOrLengthChanged || now - lastScrollbarTraceAt >= 1 else { return }
    lastScrollbarTraceAt = now
    surfaceScrollLogger.diagnostic(
      "[ScrollTrace] scrollbar wrapper=\(debugID) host=\(hostKind.rawValue) "
        + "maxMode=\(isCanvasMaxModeActive) "
        + "surface=\(surfaceView.debugIdentifierForLogging) total=\(total) offset=\(offset) "
        + "length=\(length) live=\(isLiveScrolling) userScrolledBack=\(isUserScrolledBack) "
        + "pinned=\(Self.sizeDescription(pinnedSize))"
    )
  }

  private func traceLiveScroll(row: Int, visibleRect: CGRect) {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastLiveScrollTraceAt >= 0.5 else { return }
    lastLiveScrollTraceAt = now
    surfaceScrollLogger.diagnostic(
      "[ScrollTrace] liveScroll wrapper=\(debugID) host=\(hostKind.rawValue) "
        + "maxMode=\(isCanvasMaxModeActive) "
        + "surface=\(surfaceView.debugIdentifierForLogging) row=\(row) "
        + "visibleY=\(Int(visibleRect.origin.y)) visibleH=\(Int(visibleRect.height)) "
        + "documentH=\(Int(documentView.frame.height))"
    )
  }

  private func traceWrapperScroll(_ name: String) {
    surfaceScrollLogger.diagnostic(
      "[ScrollTrace] \(name) wrapper=\(debugID) host=\(hostKind.rawValue) "
        + "maxMode=\(isCanvasMaxModeActive) "
        + "surface=\(surfaceView.debugIdentifierForLogging) "
        + "pinned=\(Self.sizeDescription(pinnedSize))"
    )
  }

  private static func sizeDescription(_ size: CGSize?) -> String {
    guard let size else { return "nil" }
    return "\(Int(size.width))x\(Int(size.height))"
  }

  override func mouseMoved(with event: NSEvent) {
    guard NSScroller.preferredScrollerStyle == .legacy else { return }
    scrollView.flashScrollers()
  }

  override func updateTrackingAreas() {
    for trackingArea in trackingAreas {
      removeTrackingArea(trackingArea)
    }
    super.updateTrackingAreas()
    guard let scroller = scrollView.verticalScroller else { return }
    addTrackingArea(
      NSTrackingArea(
        rect: convert(scroller.bounds, from: scroller),
        options: [
          .mouseMoved,
          .activeInKeyWindow,
        ],
        owner: self,
        userInfo: nil
      ))
  }
}
