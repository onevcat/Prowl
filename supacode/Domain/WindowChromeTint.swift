import AppKit
import SwiftUI

/// Unified color logic for the window *chrome* tint — the nav-panel band
/// behind the floating glass sidebar and the toolbar band behind the
/// transparent titlebar — shared across every view mode (Normal, Shelf,
/// Canvas).
///
/// The tint is "driven from the detail side": both bands are overlays on
/// the full-bleed detail content that bleed up under the titlebar and left
/// under the sidebar glass, so one resolved color paints the nav and the
/// toolbar as a single continuous "L".
///
/// `WindowTintMode` selects the source:
/// - `.none` ⇒ no band (neutral system chrome).
/// - `.repositoryColor` ⇒ the active repo's pinned color, or a neutral
///   surface when uncolored. Shelf spines can use the same repo-color pair,
///   or their own user-selected fallback behavior.
/// - `.custom` ⇒ a single user-chosen color, ignoring per-repo colors.
enum WindowChromeTint {
  enum ToolbarFallbackEvent {
    case windowState(isFullScreen: Bool)
    case willEnterFullScreen
    case didEnterFullScreen
    case willExitFullScreen
    case didExitFullScreen
  }

  struct RGBComponents: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color {
      Color(.sRGB, red: red, green: green, blue: blue)
    }

    var luminance: Double {
      0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
  }

  /// A resolved chrome band: a base color plus the alpha it should be
  /// filled at. `nil` from `fill(...)` means "draw no band".
  struct Fill: Equatable {
    var color: Color
    var alpha: Double
  }

  /// Peak fill alpha for a saturated tint (a colored repo, or a custom
  /// color). Matches the Shelf spine's open-book peak so the chrome and
  /// the spine read at the same intensity.
  static let saturatedPeakAlpha: Double = 0.20
  /// Gentler peak for the neutral fallback: `Color.primary` reads as a
  /// distinct panel at far lower opacity than a saturated hue, so 0.20
  /// would look like a glaring mid-gray instead of the subtle near-black /
  /// near-white surface we want.
  static let neutralPeakAlpha: Double = 0.10

  /// Base hue for a repository-color surface: the pinned color, or
  /// `Color.primary` for the neutral fallback. Used by `.repositoryColor`
  /// chrome bands.
  static func repositoryBase(for color: RepositoryColorChoice?) -> Color {
    color?.color ?? .primary
  }

  /// Peak alpha for a repository-color surface — the saturated peak for a
  /// pinned color, the neutral peak when uncolored.
  static func repositoryPeakAlpha(for color: RepositoryColorChoice?) -> Double {
    color == nil ? neutralPeakAlpha : saturatedPeakAlpha
  }

  /// Surface hue and peak alpha for a Shelf spine. When
  /// `followsRepositoryColor` is true, a pinned repo color wins (saturated
  /// peak); otherwise every spine uses the user's fallback style — `.neutral`
  /// stays gentler, `.systemTint` uses the saturated shelf/chrome peak. Base
  /// and alpha share one branch so they can never disagree.
  static func shelfSpineSurface(
    for color: RepositoryColorChoice?,
    fallback: ShelfSpineTintFallback,
    followsRepositoryColor: Bool
  ) -> (base: Color, peakAlpha: Double) {
    if followsRepositoryColor, let color {
      return (color.color, saturatedPeakAlpha)
    }
    let peakAlpha = fallback == .neutral ? neutralPeakAlpha : saturatedPeakAlpha
    return (shelfSpineFallbackBase(fallback), peakAlpha)
  }

  private static func shelfSpineFallbackBase(_ fallback: ShelfSpineTintFallback) -> Color {
    switch fallback {
    case .neutral:
      return .primary
    case .systemTint:
      return .accentColor
    }
  }

  /// Resolves the chrome band for the given tint mode. Returns `nil` when
  /// no band should be drawn (`.none`, or `.custom` without a color).
  ///
  /// - Parameters:
  ///   - mode: the user's window tint mode.
  ///   - customColor: the user's custom color, for `.custom` mode.
  ///   - repositoryColor: the active repo's pinned color (the open book in
  ///     Shelf, the selected worktree's repo in Normal, the focused card's
  ///     repo in Canvas), used by `.repositoryColor` mode.
  static func fill(
    mode: WindowTintMode,
    customColor: Color?,
    repositoryColor: RepositoryColorChoice?
  ) -> Fill? {
    switch mode {
    case .none:
      return nil
    case .repositoryColor:
      return Fill(
        color: repositoryBase(for: repositoryColor),
        alpha: repositoryPeakAlpha(for: repositoryColor)
      )
    case .custom:
      guard let customColor else { return nil }
      return Fill(color: customColor, alpha: saturatedPeakAlpha)
    }
  }

  /// Resolves the fallback fullscreen toolbar background to an opaque sRGB
  /// color under the requested app appearance. The normal window path keeps
  /// the toolbar background hidden so the original content tint / system
  /// material composition remains untouched; this fallback is only for the
  /// fullscreen AppKit toolbar surface, which can stop sampling the content
  /// behind it.
  static func fullscreenToolbarBackgroundComponents(
    fill: Fill?,
    colorScheme: ColorScheme
  ) -> RGBComponents {
    let base = resolvedComponents(for: NSColor.windowBackgroundColor, colorScheme: colorScheme)
    guard let fill else {
      return base
    }

    let overlay = resolvedComponents(for: fill.color, colorScheme: colorScheme)
    let alpha = min(max(fill.alpha, 0), 1)
    return RGBComponents(
      red: overlay.red * alpha + base.red * (1 - alpha),
      green: overlay.green * alpha + base.green * (1 - alpha),
      blue: overlay.blue * alpha + base.blue * (1 - alpha)
    )
  }

  private static func resolvedComponents(for color: Color, colorScheme: ColorScheme) -> RGBComponents {
    resolvedComponents(for: NSColor(color), colorScheme: colorScheme)
  }

  private static func resolvedComponents(for color: NSColor, colorScheme: ColorScheme) -> RGBComponents {
    withAppearance(for: colorScheme) {
      let resolved = color.usingColorSpace(.sRGB) ?? fallbackColor(for: colorScheme)
      return RGBComponents(
        red: Double(resolved.redComponent),
        green: Double(resolved.greenComponent),
        blue: Double(resolved.blueComponent)
      )
    }
  }

  private static func withAppearance<T>(for colorScheme: ColorScheme, _ body: () -> T) -> T {
    guard let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) else {
      return body()
    }

    var result: T?
    appearance.performAsCurrentDrawingAppearance {
      result = body()
    }
    return result!
  }

  private static func fallbackColor(for colorScheme: ColorScheme) -> NSColor {
    colorScheme == .dark ? .black : .white
  }

  static func usesExplicitToolbarBackground(isFullScreen: Bool) -> Bool {
    isFullScreen
  }

  static func toolbarFallbackState(current: Bool, event: ToolbarFallbackEvent) -> Bool {
    switch event {
    case .windowState(let isFullScreen):
      return isFullScreen
    case .willEnterFullScreen, .didEnterFullScreen, .willExitFullScreen:
      return true
    case .didExitFullScreen:
      return false
    }
  }
}

extension View {
  /// Overlays chrome tint bands on full-bleed detail content. The bands
  /// fill the safe-area insets the window reserves for the toolbar (top)
  /// and the floating sidebar (leading), bleeding past them via
  /// `ignoresSafeArea` so the color reaches under the titlebar / sidebar
  /// glass. A `nil` fill draws nothing.
  ///
  /// - Parameters:
  ///   - fill: the resolved band fill, or `nil` for no tint.
  ///   - edges: which chrome regions to tint — `.top` (toolbar) and/or
  ///     `.leading` (nav). Normal uses both; Canvas uses `.leading` only.
  func windowChromeTint(_ fill: WindowChromeTint.Fill?, edges: Edge.Set) -> some View {
    modifier(WindowChromeTintModifier(fill: fill, edges: edges))
  }

  /// Sets the real SwiftUI/AppKit window toolbar background. This is kept
  /// separate from `windowChromeTint`: the tint bands color the content
  /// behind full-bleed chrome, while the toolbar itself must also have an
  /// explicit background because macOS can stop sampling that content when
  /// a window is zoomed or fullscreen.
  func windowToolbarChromeBackground(
    _ fill: WindowChromeTint.Fill?,
    forceMaterialScrim: Bool = false
  ) -> some View {
    modifier(WindowToolbarChromeBackgroundModifier(fill: fill, forceMaterialScrim: forceMaterialScrim))
  }
}

/// Measures the toolbar (top) and sidebar (leading) safe-area insets of
/// the detail content and paints a band into each requested edge.
private struct WindowChromeTintModifier: ViewModifier {
  let fill: WindowChromeTint.Fill?
  let edges: Edge.Set

  @State private var topInset: CGFloat = 0
  @State private var leadingInset: CGFloat = 0

  func body(content: Content) -> some View {
    content
      // Content draws under the transparent titlebar, so the top
      // safe-area inset equals the toolbar/titlebar height — exactly the
      // region the top band should fill.
      .onGeometryChange(for: CGFloat.self) {
        $0.safeAreaInsets.top
      } action: {
        topInset = $0
      }
      // The detail is laid out full-bleed beneath the floating glass
      // sidebar, so the leading inset equals the sidebar width — the span
      // the leading band fills to color the nav.
      .onGeometryChange(for: CGFloat.self) {
        $0.safeAreaInsets.leading
      } action: {
        leadingInset = $0
      }
      .overlay(alignment: .top) {
        if let fill, edges.contains(.top) {
          band(fill)
            .frame(height: topInset)
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(.container, edges: .top)
        }
      }
      .overlay(alignment: .leading) {
        if let fill, edges.contains(.leading) {
          band(fill)
            .frame(width: leadingInset)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: [.leading, .top, .bottom])
        }
      }
  }

  private func band(_ fill: WindowChromeTint.Fill) -> some View {
    fill.color
      .opacity(fill.alpha)
      .allowsHitTesting(false)
  }
}

private struct WindowToolbarChromeBackgroundModifier: ViewModifier {
  let fill: WindowChromeTint.Fill?
  /// When true (a Canvas card is expanded in place), forces a neutral material
  /// scrim onto the otherwise-transparent Canvas toolbar so the background cards
  /// don't show through above the expanded card. Crucially this stays the same
  /// modifier (only its inputs change), so toggling it never re-creates the
  /// detail content / Canvas view.
  let forceMaterialScrim: Bool
  @Environment(\.colorScheme) private var colorScheme
  @State private var isFullScreen = false

  @ViewBuilder
  func body(content: Content) -> some View {
    let colorBackground = WindowChromeTint.fullscreenToolbarBackgroundComponents(
      fill: fill,
      colorScheme: colorScheme
    ).color
    // `.bar` is a theme-adaptive material (light → pale grey, dark → dark grey).
    let background: AnyShapeStyle =
      forceMaterialScrim ? AnyShapeStyle(.bar) : AnyShapeStyle(colorBackground)
    let visibility: Visibility =
      forceMaterialScrim || WindowChromeTint.usesExplicitToolbarBackground(isFullScreen: isFullScreen)
      ? .visible : .hidden

    content
      .toolbarBackground(background, for: .windowToolbar)
      .toolbarBackgroundVisibility(visibility, for: .windowToolbar)
      .background { WindowFullScreenReader(isFullScreen: $isFullScreen) }
  }
}

private struct WindowFullScreenReader: NSViewRepresentable {
  @Binding var isFullScreen: Bool

  func makeNSView(context: Context) -> WindowFullScreenReaderView {
    let view = WindowFullScreenReaderView()
    view.onFullScreenChange = makeChangeHandler()
    return view
  }

  func updateNSView(_ nsView: WindowFullScreenReaderView, context: Context) {
    nsView.onFullScreenChange = makeChangeHandler()
    nsView.refresh()
  }

  private func makeChangeHandler() -> (Bool) -> Void {
    let binding = $isFullScreen
    return { isFullScreen in
      guard binding.wrappedValue != isFullScreen else { return }
      DispatchQueue.main.async {
        guard binding.wrappedValue != isFullScreen else { return }
        binding.wrappedValue = isFullScreen
      }
    }
  }
}

@MainActor
private final class WindowFullScreenReaderView: NSView {
  var onFullScreenChange: ((Bool) -> Void)?

  private weak var observedWindow: NSWindow?
  private var observers: [NSObjectProtocol] = []

  deinit {
    MainActor.assumeIsolated {
      removeObservers()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateObservedWindow()
  }

  func refresh() {
    updateObservedWindow()
    publishFullScreenState()
  }

  private func updateObservedWindow() {
    guard observedWindow !== window else { return }

    removeObservers()
    observedWindow = window

    guard let window else {
      // SwiftUI can temporarily detach this reader while rebuilding the
      // toolbar host. Detach is not an exit-fullscreen signal; publishing
      // `false` here would hide the fallback background for one frame and
      // produce a visible flicker.
      return
    }

    observe(window, name: NSWindow.willEnterFullScreenNotification) { [weak self] in
      self?.publishFullScreenEvent(.willEnterFullScreen)
    }
    observe(window, name: NSWindow.didEnterFullScreenNotification) { [weak self] in
      self?.publishFullScreenEvent(.didEnterFullScreen)
    }
    observe(window, name: NSWindow.willExitFullScreenNotification) { [weak self] in
      self?.publishFullScreenEvent(.willExitFullScreen)
    }
    observe(window, name: NSWindow.didExitFullScreenNotification) { [weak self] in
      self?.publishFullScreenEvent(.didExitFullScreen)
    }

    publishFullScreenState()
  }

  private func observe(
    _ window: NSWindow,
    name: NSNotification.Name,
    handler: @escaping @MainActor () -> Void
  ) {
    let observer = NotificationCenter.default.addObserver(
      forName: name,
      object: window,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        handler()
      }
    }
    observers.append(observer)
  }

  private func removeObservers() {
    let notificationCenter = NotificationCenter.default
    for observer in observers {
      notificationCenter.removeObserver(observer)
    }
    observers.removeAll()
  }

  private func publishFullScreenState() {
    guard let window else { return }
    publishFullScreenEvent(.windowState(isFullScreen: window.styleMask.contains(.fullScreen)))
  }

  private func publishFullScreenEvent(_ event: WindowChromeTint.ToolbarFallbackEvent) {
    onFullScreenChange?(
      WindowChromeTint.toolbarFallbackState(
        current: window?.styleMask.contains(.fullScreen) == true,
        event: event
      )
    )
  }
}
