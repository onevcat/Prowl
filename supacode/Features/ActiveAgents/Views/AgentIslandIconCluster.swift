import AppKit
import QuartzCore
import SwiftUI

/// A compact, island-owned projection of the real Active Agents roster.
struct AgentIslandIconCluster: View {
  struct Projection: Equatable {
    let entries: [ActiveAgentEntry]
    let overflowCount: Int

    var identity: ProjectionIdentity {
      ProjectionIdentity(ids: entries.map(\.id), overflowCount: overflowCount)
    }
  }

  /// What the swap animation reacts to. Entries refresh every second (titles, timestamps), and
  /// keying the animation on the full value would open an animated transaction on each refresh,
  /// animating any concurrent layout shift; only membership, order, and overflow move icons.
  struct ProjectionIdentity: Equatable {
    let ids: [ActiveAgentEntry.ID]
    let overflowCount: Int
  }

  private static let maximumVisibleIcons = 3

  let projection: Projection
  /// Icon diameter; the notched bar passes a smaller size because it is only as tall as the cutout.
  let pointSize: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(entries: [ActiveAgentEntry], pointSize: CGFloat = 21) {
    projection = Self.projection(for: entries)
    self.pointSize = pointSize
  }

  var body: some View {
    iconRow
      // Each icon is a `pointSize + 2` circle with 2pt of padding, so the cluster is exactly one
      // padded icon tall.
      .frame(width: 78, height: pointSize + 6, alignment: .trailing)
      .animation(
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.32),
        value: projection.identity
      )
      .accessibilityHidden(true)
  }

  private var iconRow: some View {
    ZStack(alignment: .bottomTrailing) {
      HStack(spacing: -4) {
        ForEach(projection.entries) { entry in
          AgentIslandRuntimeIcon(
            entry: entry,
            pointSize: pointSize,
            allowsRingAnimation: false
          )
          .transition(iconTransition)
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)

      if projection.overflowCount > 0 {
        Text("+\(projection.overflowCount)")
          .font(.system(size: 8, weight: .bold, design: .rounded))
          .foregroundStyle(.white.opacity(0.82))
          .padding(.horizontal, 2)
          .background(.black.opacity(0.92), in: Capsule())
          .offset(x: 2, y: 2)
          .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .bottomTrailing))
      }
    }
  }

  private var iconTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .offset(x: -5)
      .combined(with: .scale(scale: 0.55, anchor: .leading))
      .combined(with: .opacity)
  }

  static func projection(for entries: [ActiveAgentEntry]) -> Projection {
    let ordered = entries.enumerated()
      .sorted { lhs, rhs in
        let lhsIsIdle = lhs.element.displayState == .idle
        let rhsIsIdle = rhs.element.displayState == .idle
        if lhsIsIdle != rhsIsIdle {
          return !lhsIsIdle
        }
        if lhs.element.lastChangedAt != rhs.element.lastChangedAt {
          return lhs.element.lastChangedAt > rhs.element.lastChangedAt
        }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
    return Projection(
      entries: Array(ordered.prefix(maximumVisibleIcons)),
      overflowCount: max(0, ordered.count - maximumVisibleIcons)
    )
  }
}

struct AgentIslandRingPresentation: Equatable {
  let animates: Bool
  let rotationDuration: TimeInterval

  static func presentation(for state: AgentDisplayState) -> Self {
    switch state {
    case .working:
      return Self(animates: true, rotationDuration: 2.6)
    case .blocked:
      return Self(animates: true, rotationDuration: 1.35)
    case .done:
      return Self(animates: true, rotationDuration: 3.4)
    case .idle:
      return Self(animates: false, rotationDuration: 0)
    }
  }
}

struct AgentIslandRuntimeIcon: View {
  let entry: ActiveAgentEntry
  let pointSize: CGFloat
  let allowsRingAnimation: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    entry: ActiveAgentEntry,
    pointSize: CGFloat,
    allowsRingAnimation: Bool = true
  ) {
    self.entry = entry
    self.pointSize = pointSize
    self.allowsRingAnimation = allowsRingAnimation
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(.white.opacity(0.06))
      Group {
        if let source = entry.iconSource {
          TabIconImage(rawName: source.storageString, pointSize: pointSize - 5)
        } else {
          Image(systemName: "sparkle")
            .font(.system(size: pointSize * 0.56, weight: .semibold))
            .accessibilityHidden(true)
        }
      }
      .foregroundStyle(.white.opacity(0.92))
    }
    // The ring circle is one point wider in radius than the glyph budget so the glyph and the
    // state ring do not touch.
    .frame(width: pointSize + 2, height: pointSize + 2)
    .overlay {
      AgentIslandStateRing(
        state: entry.displayState,
        reduceMotion: reduceMotion,
        allowsAnimation: allowsRingAnimation
      )
      .allowsHitTesting(false)
    }
    .padding(2)
    .accessibilityHidden(true)
  }
}

private struct AgentIslandStateRing: NSViewRepresentable {
  let state: AgentDisplayState
  let reduceMotion: Bool
  let allowsAnimation: Bool

  func makeNSView(context: Context) -> AgentIslandStateRingView {
    let view = AgentIslandStateRingView()
    view.update(state: state, reduceMotion: reduceMotion, allowsAnimation: allowsAnimation)
    return view
  }

  func updateNSView(_ nsView: AgentIslandStateRingView, context: Context) {
    nsView.update(state: state, reduceMotion: reduceMotion, allowsAnimation: allowsAnimation)
  }
}

@MainActor
final class AgentIslandStateRingView: NSView {
  private static let rotationAnimationKey = "agent-island-ring-rotation"

  private let baseRingLayer = CAShapeLayer()
  private let animatedRingLayer = CAGradientLayer()
  private let animatedRingMask = CAShapeLayer()
  private var rotationDuration: TimeInterval?
  private var currentState = AgentDisplayState.idle
  private var currentReduceMotion = false
  private var currentAllowsAnimation = true

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    baseRingLayer.fillColor = NSColor.clear.cgColor
    animatedRingLayer.type = .conic
    animatedRingLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
    animatedRingLayer.endPoint = CGPoint(x: 0.5, y: 0)
    animatedRingLayer.mask = animatedRingMask
    animatedRingMask.fillColor = NSColor.clear.cgColor
    animatedRingMask.strokeColor = NSColor.white.cgColor
    animatedRingMask.lineWidth = 2.2
    animatedRingMask.lineCap = .round
    layer?.addSublayer(baseRingLayer)
    layer?.addSublayer(animatedRingLayer)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let ringBounds = bounds.insetBy(dx: 1.2, dy: 1.2)
    let path = CGPath(ellipseIn: ringBounds, transform: nil)
    baseRingLayer.frame = bounds
    baseRingLayer.path = path
    animatedRingLayer.frame = bounds
    animatedRingMask.frame = bounds
    animatedRingMask.path = path
    CATransaction.commit()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateContentsScale()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateContentsScale()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyPresentation()
  }

  func update(
    state: AgentDisplayState,
    reduceMotion: Bool,
    allowsAnimation: Bool = true
  ) {
    currentState = state
    currentReduceMotion = reduceMotion
    currentAllowsAnimation = allowsAnimation
    applyPresentation()
  }

  var isRotationActive: Bool {
    animatedRingLayer.animation(forKey: Self.rotationAnimationKey) != nil
  }

  var isAnimatedRingVisible: Bool {
    !animatedRingLayer.isHidden
  }

  private func applyPresentation() {
    let presentation = AgentIslandRingPresentation.presentation(for: currentState)
    let color = resolvedColor(for: currentState)
    let presentsAnimatedRing = presentation.animates && currentAllowsAnimation
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    baseRingLayer.strokeColor = color.withAlphaComponent(presentsAnimatedRing ? 0.2 : 0.42).cgColor
    baseRingLayer.lineWidth = presentsAnimatedRing ? 1.1 : 1
    animatedRingLayer.isHidden = !presentsAnimatedRing
    animatedRingLayer.colors = Self.gradientAlphas.map {
      color.withAlphaComponent($0).cgColor
    }
    animatedRingLayer.locations = Self.gradientLocations
    animatedRingLayer.shadowColor = color.cgColor
    animatedRingLayer.shadowOpacity = presentsAnimatedRing ? 0.3 : 0
    animatedRingLayer.shadowRadius = 1.4
    animatedRingLayer.shadowOffset = .zero
    CATransaction.commit()

    if presentsAnimatedRing, !currentReduceMotion {
      startRotation(duration: presentation.rotationDuration)
    } else {
      stopRotation()
    }
  }

  private func startRotation(duration: TimeInterval) {
    guard rotationDuration != duration || !isRotationActive else { return }
    let animation = CABasicAnimation(keyPath: "transform.rotation.z")
    animation.fromValue = 0
    animation.toValue = Double.pi * 2
    animation.duration = duration
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false
    animatedRingLayer.add(animation, forKey: Self.rotationAnimationKey)
    rotationDuration = duration
  }

  private func stopRotation() {
    animatedRingLayer.removeAnimation(forKey: Self.rotationAnimationKey)
    rotationDuration = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    animatedRingLayer.transform = CATransform3DIdentity
    CATransaction.commit()
  }

  private func updateContentsScale() {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    baseRingLayer.contentsScale = scale
    animatedRingLayer.contentsScale = scale
    animatedRingMask.contentsScale = scale
  }

  private func resolvedColor(for state: AgentDisplayState) -> NSColor {
    var color: NSColor?
    effectiveAppearance.performAsCurrentDrawingAppearance {
      color =
        switch state {
        case .working:
          .systemOrange
        case .blocked:
          .systemRed
        case .done:
          .systemBlue
        case .idle:
          .secondaryLabelColor
        }
    }
    return color ?? .secondaryLabelColor
  }

  private static let gradientAlphas: [CGFloat] = [0.08, 0.34, 1, 0.28, 0.72, 0.08]
  private static let gradientLocations: [NSNumber] = [0, 0.18, 0.36, 0.62, 0.82, 1]
}
