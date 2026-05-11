import Foundation
import Testing

@testable import supacode

struct CanvasCardDebugStyleTests {
  @Test func defaultStyleKeepsExistingCardAppearance() {
    let style = CanvasCardDebugStyleConfiguration.default

    #expect(style.cardBackdrop.style == .clear)
    #expect(style.cardBackdrop.opacity == 1)
    #expect(style.titleBarBackdrop.style == .bar)
    #expect(style.titleBarBackdrop.opacity == 0.9)
    #expect(style.selectedCardTintOpacity == 0.08)
    #expect(style.selectedTitleBarTintOpacity == 0.12)
    #expect(style.notificationTintOpacity == 0.55)
    #expect(style.terminalBackgroundOpacity == nil)
    #expect(style.terminalBackgroundOpacityCells == nil)
  }

  @Test func decodesGlassPresetFromDebugJSON() throws {
    let data = Data(
      """
      {
        "cardBackdrop": {
          "style": "glassClear",
          "opacity": 0.72
        },
        "titleBarBackdrop": {
          "style": "glassRegular",
          "opacity": 0.86,
          "material": "hudWindow",
          "blendingMode": "behindWindow"
        },
        "selectedCardTintOpacity": 0.11,
        "selectedTitleBarTintOpacity": 0.18,
        "notificationTintOpacity": 0.61,
        "terminalBackgroundOpacity": 0.38,
        "terminalBackgroundOpacityCells": true
      }
      """.utf8)

    let style = try JSONDecoder().decode(CanvasCardDebugStyleConfiguration.self, from: data)

    #expect(style.cardBackdrop.style == .glassClear)
    #expect(style.cardBackdrop.opacity == 0.72)
    #expect(style.titleBarBackdrop.style == .glassRegular)
    #expect(style.titleBarBackdrop.opacity == 0.86)
    #expect(style.titleBarBackdrop.material == .hudWindow)
    #expect(style.titleBarBackdrop.blendingMode == .behindWindow)
    #expect(style.selectedCardTintOpacity == 0.11)
    #expect(style.selectedTitleBarTintOpacity == 0.18)
    #expect(style.notificationTintOpacity == 0.61)
    #expect(style.terminalBackgroundOpacity == 0.38)
    #expect(style.terminalBackgroundOpacityCells == true)
  }

  @Test func missingFieldsDecodeToCurrentDefaults() throws {
    let data = Data(
      """
      {
        "cardBackdrop": {
          "style": "visualEffect"
        }
      }
      """.utf8)

    let style = try JSONDecoder().decode(CanvasCardDebugStyleConfiguration.self, from: data)

    #expect(style.cardBackdrop.style == .visualEffect)
    #expect(style.cardBackdrop.opacity == 1)
    #expect(style.titleBarBackdrop == .defaultTitleBar)
    #expect(style.selectedCardTintOpacity == 0.08)
    #expect(style.selectedTitleBarTintOpacity == 0.12)
    #expect(style.notificationTintOpacity == 0.55)
    #expect(style.terminalBackgroundOpacity == nil)
    #expect(style.terminalBackgroundOpacityCells == nil)
  }
}
