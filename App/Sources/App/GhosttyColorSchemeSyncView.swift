import SwiftUI

struct GhosttyColorSchemeSyncView<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  let ghostty: GhosttyRuntime
  let preferredColorScheme: ColorScheme?
  let content: Content

  init(
    ghostty: GhosttyRuntime,
    preferredColorScheme: ColorScheme? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.ghostty = ghostty
    self.preferredColorScheme = preferredColorScheme
    self.content = content()
  }

  var body: some View {
    content
      .task {
        apply(effectiveColorScheme)
      }
      .onChange(of: colorScheme) { _, newValue in
        apply(preferredColorScheme ?? newValue)
      }
      .onChange(of: preferredColorScheme) { _, newValue in
        apply(newValue ?? colorScheme)
      }
  }

  private var effectiveColorScheme: ColorScheme {
    preferredColorScheme ?? colorScheme
  }

  private func apply(_ scheme: ColorScheme) {
    ghostty.setColorScheme(scheme)
  }
}
