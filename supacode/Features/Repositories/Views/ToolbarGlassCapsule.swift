import SwiftUI

/// The glass pill the toolbar items left of the branch title draw for
/// themselves. They opt out of the navigation group's shared background
/// (`sharedBackgroundVisibility(.hidden)` at the call site) to stay separate
/// from the branch title, so the chrome has to come from here.
///
/// `.plain` plus an explicit glass background keeps the horizontal padding as
/// tight as the other toolbar buttons; `.buttonStyle(.glass)` pads noticeably
/// wider. Hover feedback must live in the material itself: a translucent fill
/// layered under `glassEffect` is swallowed by the compositing, and
/// `.interactive()` only adds press feedback on macOS.
struct ToolbarGlassCapsule: ViewModifier {
  let isHighlighted: Bool

  func body(content: Content) -> some View {
    content
      .buttonStyle(.plain)
      .glassEffect(
        isHighlighted ? .regular.tint(.primary.opacity(0.12)).interactive() : .regular.interactive(),
        in: Capsule()
      )
  }
}

extension View {
  /// Applies the toolbar capsule chrome; `isHighlighted` carries hover.
  func toolbarGlassCapsule(isHighlighted: Bool) -> some View {
    modifier(ToolbarGlassCapsule(isHighlighted: isHighlighted))
  }

  /// The label metrics every toolbar pill shares with `WorktreeDetailTitleView`.
  func toolbarCapsuleLabel() -> some View {
    font(.title3.weight(.medium))
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .contentShape(Capsule())
  }
}
