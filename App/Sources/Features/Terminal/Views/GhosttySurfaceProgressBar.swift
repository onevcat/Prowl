import GhosttyKit
import SwiftUI

struct GhosttySurfaceProgressBar: View {
  let progressState: ghostty_action_progress_report_state_e
  let progressValue: Int?

  var body: some View {
    let color: Color =
      switch progressState {
      case GHOSTTY_PROGRESS_STATE_ERROR: .red
      case GHOSTTY_PROGRESS_STATE_PAUSE: .orange
      default: .accentColor
      }
    let progress: Int? =
      progressValue.map(Self.bucketedPercent) ?? (progressState == GHOSTTY_PROGRESS_STATE_PAUSE ? 100 : nil)
    let accessibilityLabel: String =
      switch progressState {
      case GHOSTTY_PROGRESS_STATE_ERROR: String(localized: "Terminal progress - Error")
      case GHOSTTY_PROGRESS_STATE_PAUSE: String(localized: "Terminal progress - Paused")
      case GHOSTTY_PROGRESS_STATE_INDETERMINATE: String(localized: "Terminal progress - In progress")
      default: String(localized: "Terminal progress")
      }
    let accessibilityValue: String =
      if let progress {
        String(localized: "\(progress) percent complete")
      } else {
        switch progressState {
        case GHOSTTY_PROGRESS_STATE_ERROR: String(localized: "Operation failed")
        case GHOSTTY_PROGRESS_STATE_PAUSE: String(localized: "Operation paused at completion")
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE: String(localized: "Operation in progress")
        default: String(localized: "Indeterminate progress")
        }
      }

    Group {
      if let progress {
        // Leading-anchored scaleEffect composites a percent step instead of
        // relaying out a GeometryReader frame width on every OSC-9 tick.
        Rectangle()
          .fill(color)
          .scaleEffect(x: CGFloat(progress) / 100, y: 1, anchor: .leading)
      } else {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Rectangle()
              .fill(color.opacity(0.3))
            Rectangle()
              .fill(color)
              .frame(width: geometry.size.width * 0.25, height: geometry.size.height)
              .phaseAnimator([false, true]) { content, moved in
                content.offset(x: moved ? geometry.size.width * 0.75 : 0)
              } animation: { _ in
                .easeInOut(duration: 1.2)
              }
          }
        }
      }
    }
    .frame(height: 2)
    .clipped()
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.updatesFrequently)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
  }

  /// Quantize a determinate percent to 5% steps so a 0->100 sweep collapses to
  /// ~20 distinct values that mostly no-op at the view's equality gates. 0 and
  /// the >=100 terminus pass through unchanged so the bar still empties and tops
  /// out exactly.
  static func bucketedPercent(_ percent: Int) -> Int {
    guard percent > 0 else { return 0 }
    guard percent < 100 else { return 100 }
    return (percent / 5) * 5
  }
}
