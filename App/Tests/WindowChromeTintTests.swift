import AppKit
import SwiftUI
import Testing

@testable import supacode

struct WindowChromeTintTests {
  // MARK: - fill(mode:customColor:repositoryColor:)

  @Test
  func noneModeNeverDrawsABand() {
    #expect(WindowChromeTint.fill(mode: .none, customColor: nil, repositoryColor: nil) == nil)
    #expect(WindowChromeTint.fill(mode: .none, customColor: .green, repositoryColor: .red) == nil)
  }

  @Test
  func repositoryColorModeUsesRepoColorAtSaturatedAlpha() {
    let fill = WindowChromeTint.fill(mode: .repositoryColor, customColor: nil, repositoryColor: .red)
    #expect(fill == WindowChromeTint.Fill(color: .red, alpha: WindowChromeTint.saturatedPeakAlpha))
  }

  @Test
  func repositoryColorModeFallsBackToNeutralSurfaceWhenUncolored() {
    let fill = WindowChromeTint.fill(mode: .repositoryColor, customColor: nil, repositoryColor: nil)
    #expect(fill == WindowChromeTint.Fill(color: .primary, alpha: WindowChromeTint.neutralPeakAlpha))
  }

  @Test
  func customModeUsesCustomColorAndIgnoresRepoColor() {
    let fill = WindowChromeTint.fill(mode: .custom, customColor: .green, repositoryColor: .red)
    #expect(fill == WindowChromeTint.Fill(color: .green, alpha: WindowChromeTint.saturatedPeakAlpha))
  }

  @Test
  func customModeWithoutAColorDrawsNoBand() {
    #expect(WindowChromeTint.fill(mode: .custom, customColor: nil, repositoryColor: .red) == nil)
  }

  // MARK: - Repository surface helpers (shared with the Shelf spine)

  @Test
  func repositoryPeakAlphaIsGentlerWhenUncolored() {
    #expect(WindowChromeTint.repositoryPeakAlpha(for: nil) == WindowChromeTint.neutralPeakAlpha)
    #expect(WindowChromeTint.repositoryPeakAlpha(for: .blue) == WindowChromeTint.saturatedPeakAlpha)
  }

  @Test
  func shelfSpineUsesNeutralFallbackByDefaultForUncoloredRepositories() {
    let surface = WindowChromeTint.shelfSpineSurface(
      for: nil,
      fallback: .neutral,
      followsRepositoryColor: true
    )
    #expect(surface.base == .primary)
    #expect(surface.peakAlpha == WindowChromeTint.neutralPeakAlpha)
  }

  @Test
  func shelfSpineCanUseSystemTintFallbackForUncoloredRepositories() {
    let surface = WindowChromeTint.shelfSpineSurface(
      for: nil,
      fallback: .systemTint,
      followsRepositoryColor: true
    )
    #expect(surface.base == .accentColor)
    #expect(surface.peakAlpha == WindowChromeTint.saturatedPeakAlpha)
  }

  @Test
  func shelfSpineFollowsRepositoryColorAtSaturatedAlpha() {
    // A pinned color wins regardless of the fallback when following is on.
    let surface = WindowChromeTint.shelfSpineSurface(
      for: .green,
      fallback: .neutral,
      followsRepositoryColor: true
    )
    #expect(surface.base == .green)
    #expect(surface.peakAlpha == WindowChromeTint.saturatedPeakAlpha)
  }

  @Test
  func shelfSpineCanIgnoreRepositoryColors() {
    // With following off, the fallback style drives both base and alpha even
    // for a colored repo.
    let neutral = WindowChromeTint.shelfSpineSurface(
      for: .green,
      fallback: .neutral,
      followsRepositoryColor: false
    )
    #expect(neutral.base == .primary)
    #expect(neutral.peakAlpha == WindowChromeTint.neutralPeakAlpha)

    let systemTint = WindowChromeTint.shelfSpineSurface(
      for: .green,
      fallback: .systemTint,
      followsRepositoryColor: false
    )
    #expect(systemTint.base == .accentColor)
    #expect(systemTint.peakAlpha == WindowChromeTint.saturatedPeakAlpha)
  }

  // MARK: - Toolbar background resolution

  @Test
  func fullscreenToolbarBackgroundUsesRequestedColorSchemeForNeutralChrome() {
    let light = WindowChromeTint.fullscreenToolbarBackgroundComponents(fill: nil, colorScheme: .light)
    let dark = WindowChromeTint.fullscreenToolbarBackgroundComponents(fill: nil, colorScheme: .dark)

    #expect(light.luminance > dark.luminance)
  }

  @Test
  func fullscreenToolbarBackgroundUsesRequestedColorSchemeForPrimaryTintFallback() {
    let fill = WindowChromeTint.Fill(color: .primary, alpha: WindowChromeTint.neutralPeakAlpha)
    let light = WindowChromeTint.fullscreenToolbarBackgroundComponents(fill: fill, colorScheme: .light)
    let dark = WindowChromeTint.fullscreenToolbarBackgroundComponents(fill: fill, colorScheme: .dark)

    #expect(light.luminance > dark.luminance)
  }

  @Test
  func fullscreenToolbarBackgroundIgnoresCurrentSystemAppearance() {
    let lightWhileCurrentIsDark = withDrawingAppearance(.darkAqua) {
      WindowChromeTint.fullscreenToolbarBackgroundComponents(fill: nil, colorScheme: .light)
    }
    let lightWhileCurrentIsLight = withDrawingAppearance(.aqua) {
      WindowChromeTint.fullscreenToolbarBackgroundComponents(fill: nil, colorScheme: .light)
    }

    #expect(lightWhileCurrentIsDark == lightWhileCurrentIsLight)
  }

  @Test
  func explicitToolbarBackgroundIsOnlyForFullscreen() {
    #expect(!WindowChromeTint.usesExplicitToolbarBackground(isFullScreen: false))
    #expect(WindowChromeTint.usesExplicitToolbarBackground(isFullScreen: true))
  }

  @Test
  func toolbarFallbackTurnsOnAtStartOfEnterFullScreenTransition() {
    #expect(
      WindowChromeTint.toolbarFallbackState(
        current: false,
        event: .willEnterFullScreen
      )
    )
    #expect(
      WindowChromeTint.toolbarFallbackState(
        current: false,
        event: .didEnterFullScreen
      )
    )
  }

  @Test
  func toolbarFallbackStaysOnUntilExitFullScreenFinishes() {
    #expect(
      WindowChromeTint.toolbarFallbackState(
        current: true,
        event: .willExitFullScreen
      )
    )
    #expect(
      !WindowChromeTint.toolbarFallbackState(
        current: true,
        event: .didExitFullScreen
      )
    )
  }

  // MARK: - TintColor persistence

  @Test
  func tintColorRoundTripsThroughSRGBComponents() throws {
    let original = TintColor(red: 0.2, green: 0.4, blue: 0.6)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(TintColor.self, from: data)
    #expect(decoded == original)
  }

  private func withDrawingAppearance<T>(_ name: NSAppearance.Name, _ body: () -> T) -> T {
    guard let appearance = NSAppearance(named: name) else {
      return body()
    }

    var result: T?
    appearance.performAsCurrentDrawingAppearance {
      result = body()
    }
    return result!
  }
}
