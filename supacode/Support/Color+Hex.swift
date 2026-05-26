import SwiftUI

internal extension Color {
  private static var redMask: UInt32 { 0xFF0000 }
  private static var greenMask: UInt32 { 0x00FF00 }
  private static var blueMask: UInt32 { 0x0000FF }
  private static var redShift: UInt32 { 16 }
  private static var greenShift: UInt32 { 8 }
  private static var rgbComponentMax: Double { 255 }

  init(rgbHex: UInt32) {
    self.init(
      red: Double((rgbHex & Self.redMask) >> Self.redShift) / Self.rgbComponentMax,
      green: Double((rgbHex & Self.greenMask) >> Self.greenShift) / Self.rgbComponentMax,
      blue: Double(rgbHex & Self.blueMask) / Self.rgbComponentMax
    )
  }
}
