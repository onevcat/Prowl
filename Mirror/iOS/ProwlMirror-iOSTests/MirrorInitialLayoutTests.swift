import SwiftUI
import Testing
import UIKit

@testable import ProwlMirror_iOS

@MainActor
struct MirrorInitialLayoutTests {
  @Test func phoneStartsOnTheDetailColumnWithTheSessionListHidden() {
    let layout = ContentView.initialLayout(for: .phone)
    #expect(layout.columns == .detailOnly)
    #expect(layout.compactColumn == .detail)
  }

  @Test(arguments: [UIUserInterfaceIdiom.pad, .mac])
  func largerDevicesShowTheSessionList(_ idiom: UIUserInterfaceIdiom) {
    let layout = ContentView.initialLayout(for: idiom)
    #expect(layout.columns == .all)
    #expect(layout.compactColumn == .sidebar)
  }
}
