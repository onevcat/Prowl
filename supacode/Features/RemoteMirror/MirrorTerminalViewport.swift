import AppKit
import GhosttyKit
import SwiftUI

struct MirrorTerminalViewport: NSViewRepresentable {
  let surface: GhosttySurfaceView
  let displaySize: CGSize
  var fitsWindow = true
  var viewportText: String?
  var scrollCompletion: UUID?

  func makeNSView(context: Context) -> MirrorTerminalScrollView {
    let view = MirrorTerminalScrollView(surface: surface, displaySize: displaySize, fitsWindow: fitsWindow)
    view.updateViewportText(viewportText)
    view.updateScrollCompletion(scrollCompletion)
    return view
  }

  func updateNSView(_ view: MirrorTerminalScrollView, context: Context) {
    view.update(surface: surface, displaySize: displaySize, fitsWindow: fitsWindow)
    view.updateViewportText(viewportText)
    view.updateScrollCompletion(scrollCompletion)
  }
}

final class MirrorTerminalScrollView: NSScrollView {
  private final class Document: NSView {
    override var isFlipped: Bool { true }
  }

  private final class ViewportTextView: NSTextView {
    weak var terminal: GhosttySurfaceView?

    override func scrollWheel(with event: NSEvent) {
      enclosingScrollView?.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
      if event.modifierFlags.contains(.command) {
        super.keyDown(with: event)
      } else {
        if let terminal { window?.makeFirstResponder(terminal) }
        terminal?.keyDown(with: event)
      }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
      if event.modifierFlags.contains(.command), ["a", "c"].contains(event.charactersIgnoringModifiers ?? "") {
        return super.performKeyEquivalent(with: event)
      }
      guard let terminal else { return super.performKeyEquivalent(with: event) }
      window?.makeFirstResponder(terminal)
      return terminal.performKeyEquivalent(with: event)
    }
  }

  private var surface: GhosttySurfaceView
  private let document = Document()
  private let viewport = ViewportTextView(frame: .zero)
  private var fitsWindow: Bool
  private var resetOrigin = true
  private var scrollCompletion: UUID?
  private var isLayingOut = false
  var displaySize: CGSize {
    didSet { if displaySize != oldValue { needsLayout = true } }
  }

  init(surface: GhosttySurfaceView, displaySize: CGSize, fitsWindow: Bool = true) {
    self.surface = surface
    self.displaySize = displaySize
    self.fitsWindow = fitsWindow
    super.init(frame: .zero)
    hasHorizontalScroller = true
    hasVerticalScroller = true
    autohidesScrollers = true
    scrollerStyle = .overlay
    drawsBackground = false
    minMagnification = 0.01
    maxMagnification = 1
    // A top-origin document also keeps short terminals at the top of larger windows.
    // The surface retains its Host grid; magnification changes only presentation.
    documentView = document
    document.addSubview(surface)
    viewport.isEditable = false
    viewport.isSelectable = true
    viewport.isRichText = false
    viewport.isHidden = true
    viewport.drawsBackground = true
    viewport.backgroundColor = .textBackgroundColor
    viewport.textColor = .textColor
    viewport.textContainerInset = .zero
    viewport.textContainer?.lineFragmentPadding = 0
    viewport.textContainer?.widthTracksTextView = false
    viewport.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    viewport.terminal = surface
    viewport.setAccessibilityIdentifier("remote-mirror-viewport-text")
    document.addSubview(viewport)
  }

  func update(surface: GhosttySurfaceView, displaySize: CGSize, fitsWindow: Bool = true) {
    if self.surface !== surface {
      self.surface.removeFromSuperview()
      self.surface = surface
      document.addSubview(surface, positioned: .below, relativeTo: viewport)
      viewport.terminal = surface
      resetOrigin = true
      needsLayout = true
    }
    if self.fitsWindow != fitsWindow {
      self.fitsWindow = fitsWindow
      resetOrigin = true
      needsLayout = true
    }
    self.displaySize = displaySize
  }

  func updateViewportText(_ text: String?) {
    let wasHidden = viewport.isHidden
    viewport.isHidden = text == nil
    if let text, viewport.string != text { viewport.string = text }
    if text == nil, window?.firstResponder === viewport { window?.makeFirstResponder(surface) }
    if wasHidden != viewport.isHidden { resetOrigin = true }
    needsLayout = true
  }

  func updateScrollCompletion(_ completion: UUID?) {
    guard scrollCompletion != completion else { return }
    scrollCompletion = completion
    guard completion != nil else { return }
    resetOrigin = true
    needsLayout = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func layout() {
    guard !isLayingOut else { return }
    isLayingOut = true
    defer { isLayingOut = false }
    let origin = resetOrigin || fitsWindow ? NSPoint.zero : contentView.bounds.origin
    super.layout()
    document.setFrameSize(displaySize)
    surface.setFrameSize(displaySize)
    surface.updateSurfaceSize()
    viewport.setFrameSize(displaySize)
    updateViewportFont()
    let scale =
      fitsWindow
      ? min(1, contentSize.width / max(1, displaySize.width), contentSize.height / max(1, displaySize.height))
      : 1
    let target = max(minMagnification, scale)
    if abs(magnification - target) > 0.0001 { magnification = target }
    let visible = contentView.bounds.size
    contentView.scroll(
      to: NSPoint(
        x: min(max(0, origin.x), max(0, displaySize.width - visible.width)),
        y: min(max(0, origin.y), max(0, displaySize.height - visible.height))
      ))
    reflectScrolledClipView(contentView)
    resetOrigin = false
  }

  private func updateViewportFont() {
    guard !viewport.isHidden, let terminal = surface.surface else { return }
    let size = ghostty_surface_size(terminal)
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = CGFloat(size.cell_height_px) / scale
    paragraph.maximumLineHeight = paragraph.minimumLineHeight
    var attributes: [NSAttributedString.Key: Any] = [
      .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph,
    ]
    if let rawFont = ghostty_surface_quicklook_font(terminal) {
      let font = Unmanaged<CTFont>.fromOpaque(rawFont)
      attributes[.font] = font.takeUnretainedValue()
      viewport.textStorage?.setAttributes(
        attributes, range: NSRange(location: 0, length: viewport.textStorage?.length ?? 0))
      font.release()
    } else {
      viewport.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }
  }
}
