import Testing

@testable import supacode

struct GhosttyUserConfigSnapshotTests {
  @Test func detectsDualTheme() {
    let snapshot = GhosttyUserConfigSnapshot.parse(
      showConfigOutput: """
        theme = light:Catppuccin Latte,dark:Catppuccin Frappe
        background = #1f1f28
        """)

    #expect(snapshot.themeMode == .dual)
  }

  @Test func detectsSingleTheme() {
    let snapshot = GhosttyUserConfigSnapshot.parse(
      showConfigOutput: """
        theme = kanagawabones
        background = #f2f2f2
        """)

    #expect(snapshot.themeMode == .single)
  }

  @Test func detectsUnsetTheme() {
    let snapshot = GhosttyUserConfigSnapshot.parse(
      showConfigOutput: """
        background = #1f1f28
        """)

    #expect(snapshot.themeMode == .none)
  }

  @Test func detectsSameNameDualThemeFromRawConfig() {
    // Ghostty's `+show-config` collapses `light:X,dark:X` to `theme = X`, but the
    // raw config keeps the explicit pair, which must be honored as dual.
    let spec = GhosttyUserConfigSnapshot.rawThemeSpec(
      fromConfig: """
        # my ghostty config
        theme = light:Everforest Dark Hard,dark:Everforest Dark Hard
        background-opacity = 0.95
        """)

    #expect(spec == "light:Everforest Dark Hard,dark:Everforest Dark Hard")
    #expect(GhosttyUserConfigSnapshot.parseThemeMode(from: spec) == .dual)
  }

  @Test func fallbackEligibilityByThemeMode() {
    // `.single` and `.none` adapt to the app appearance; `.dual` is the user's
    // explicit per-mode choice and must be left untouched.
    #expect(GhosttyThemeMode.single.allowsMismatchFallback)
    #expect(GhosttyThemeMode.none.allowsMismatchFallback)
    #expect(!GhosttyThemeMode.dual.allowsMismatchFallback)
  }

  @Test func rawThemeSpecIgnoresCommentsAndTakesLastWins() {
    #expect(
      GhosttyUserConfigSnapshot.rawThemeSpec(
        fromConfig: """
          # theme = should-be-ignored
          theme = kanagawabones
          font-size = 14
          theme = Everforest Dark Hard
          """) == "Everforest Dark Hard")

    #expect(GhosttyUserConfigSnapshot.rawThemeSpec(fromConfig: "font-size = 14\n") == nil)
  }

  @Test func classifiesBackgroundToneLightDarkUnknown() {
    let dark = GhosttyUserConfigSnapshot.parse(showConfigOutput: "background = #1a1a1a")
    #expect(dark.backgroundTone == .dark)

    let light = GhosttyUserConfigSnapshot.parse(showConfigOutput: "background = #f4f4f4")
    #expect(light.backgroundTone == .light)

    // Popular tinted dark backgrounds should still classify as dark.
    let kanagawa = GhosttyUserConfigSnapshot.parse(showConfigOutput: "background = #1f1f28")
    #expect(kanagawa.backgroundTone == .dark)

    let solarizedDark = GhosttyUserConfigSnapshot.parse(showConfigOutput: "background = #002b36")
    #expect(solarizedDark.backgroundTone == .dark)

    // Mid-luminance colors remain ambiguous and must not trigger a fallback.
    let mid = GhosttyUserConfigSnapshot.parse(showConfigOutput: "background = #808080")
    #expect(mid.backgroundTone == .unknown)
  }
}
