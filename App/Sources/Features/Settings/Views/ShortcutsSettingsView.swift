import ComposableArchitecture
import SwiftUI

struct ShortcutsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let effectiveKeybindings: ResolvedKeybindingMap
  let customCommands: [EffectiveCustomCommand]
  let islandHotKeyRegistrationFailures: [String: Keybinding]

  var body: some View {
    ShortcutSettingsEditor(
      store: store,
      effectiveKeybindings: effectiveKeybindings,
      customCommands: customCommands,
      islandHotKeyRegistrationFailures: islandHotKeyRegistrationFailures
    )
  }
}
