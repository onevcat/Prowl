import AppKit
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct ToolbarStatusViewTests {
  @Test func statusSlotKeepsStableIdealWidthAcrossToastLengths() {
    let shortToastSize = fittingSize(for: .success("Saved"))
    let longToastSize = fittingSize(for: .success(String(repeating: "Long toolbar status ", count: 40)))

    #expect(abs(shortToastSize.width - 280) < 0.5)
    #expect(abs(longToastSize.width - 280) < 0.5)
  }

  @Test func longToastRemainsSingleLineWhenToolbarIsConstrained() {
    let shortToastSize = fittingSize(for: .success("Saved"), constrainedTo: 180)
    let longToastSize = fittingSize(
      for: .success(String(repeating: "Long toolbar status ", count: 40)),
      constrainedTo: 180
    )

    #expect(longToastSize.width <= 180.5)
    #expect(abs(longToastSize.height - shortToastSize.height) < 0.5)
  }

  private func fittingSize(
    for toast: RepositoriesFeature.StatusToast,
    constrainedTo width: CGFloat? = nil
  ) -> CGSize {
    let statusView = ToolbarStatusView(toast: toast, pullRequest: nil, codeHost: .github)
    let rootView =
      if let width {
        AnyView(statusView.frame(width: width))
      } else {
        AnyView(statusView)
      }
    return NSHostingView(rootView: rootView).fittingSize
  }
}
