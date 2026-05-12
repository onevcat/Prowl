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
    #expect(style.terminalCellBackgroundOpacity == nil)
    #expect(style.terminalBackgroundBlur == nil)
    #expect(style.hotReloadEnabled)
    #expect(style.cardGlassTintOpacity == 0)
    #expect(style.terminalReadabilityScrimOpacity == 0)
    #expect(style.terminalReadabilityScrimLightColor == nil)
    #expect(style.terminalReadabilityScrimDarkColor == nil)
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
        "terminalBackgroundOpacityCells": true,
        "terminalCellBackgroundOpacity": 0.42,
        "terminalBackgroundBlur": "macos-glass-regular",
        "hotReloadEnabled": false,
        "cardGlassTintOpacity": 0.19,
        "terminalReadabilityScrimOpacity": 0.13,
        "terminalReadabilityScrimLightColor": "#F8FAFC",
        "terminalReadabilityScrimDarkColor": "#05070AFF"
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
    #expect(style.terminalCellBackgroundOpacity == 0.42)
    #expect(style.terminalBackgroundBlur == .macosGlassRegular)
    #expect(!style.hotReloadEnabled)
    #expect(style.cardGlassTintOpacity == 0.19)
    #expect(style.terminalReadabilityScrimOpacity == 0.13)
    #expect(style.terminalReadabilityScrimLightColor?.red == 248.0 / 255.0)
    #expect(style.terminalReadabilityScrimLightColor?.green == 250.0 / 255.0)
    #expect(style.terminalReadabilityScrimLightColor?.blue == 252.0 / 255.0)
    #expect(style.terminalReadabilityScrimLightColor?.alpha == 1)
    #expect(style.terminalReadabilityScrimDarkColor?.red == 5.0 / 255.0)
    #expect(style.terminalReadabilityScrimDarkColor?.green == 7.0 / 255.0)
    #expect(style.terminalReadabilityScrimDarkColor?.blue == 10.0 / 255.0)
    #expect(style.terminalReadabilityScrimDarkColor?.alpha == 1)
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
    #expect(style.terminalCellBackgroundOpacity == nil)
    #expect(style.terminalBackgroundBlur == nil)
    #expect(style.hotReloadEnabled)
    #expect(style.cardGlassTintOpacity == 0)
    #expect(style.terminalReadabilityScrimOpacity == 0)
    #expect(style.terminalReadabilityScrimLightColor == nil)
    #expect(style.terminalReadabilityScrimDarkColor == nil)
  }

  @Test func terminalOverrideIncludesIndependentCellBackgroundOpacity() throws {
    let data = Data(
      """
      {
        "terminalBackgroundOpacity": 0,
        "terminalBackgroundOpacityCells": true,
        "terminalCellBackgroundOpacity": 0.35
      }
      """.utf8)

    let style = try JSONDecoder().decode(CanvasCardDebugStyleConfiguration.self, from: data)

    #expect(
      style.terminalOverrideContents
        == """
        background-opacity = 0.001
        background-opacity-cells = true
        background-opacity-cells-alpha = 0.35
        """
    )
  }

  @MainActor
  @Test func storeLoadsDebugFileDuringInitialization() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("prowl-canvas-card-debug-\(UUID().uuidString).json")
    defer {
      try? FileManager.default.removeItem(at: fileURL)
    }
    try Data(
      """
      {
        "notificationTintOpacity": 0.27,
        "terminalBackgroundOpacity": 0.41
      }
      """.utf8
    )
    .write(to: fileURL)

    let store = CanvasCardDebugStyleStore(fileURL: fileURL)

    #expect(store.configuration.notificationTintOpacity == 0.27)
    #expect(store.configuration.terminalBackgroundOpacity == 0.41)
  }
}
