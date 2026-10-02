import AppKit
import GhosttyKit

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
  private var lastSentRow: Int?
  private var scrollbar: ScrollbarState?

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

  func updateSurfaceSize() {
    surfaceView.updateSurfaceSize()
    needsLayout = true
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
