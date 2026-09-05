import ComposableArchitecture
import SwiftUI

/// Picker identity for the display preference. Tags match by display UUID only: the stored
/// `name` is a last-known label that drifts with the system language or a rename, and a
/// full-value comparison would leave the picker without a matching tag.
enum AgentIslandDisplaySelection: Hashable {
  case automatic
  case display(id: String)

  init(_ preference: AgentIslandDisplayPreference) {
    switch preference {
    case .automatic:
      self = .automatic
    case .display(let id, _):
      self = .display(id: id)
    }
  }

  /// Rebuilds the stored preference, labeling a connected display with its current catalog name
  /// and keeping the last-known name of a display that is currently disconnected.
  func preference(
    screens: [AgentIslandScreenDescriptor],
    current: AgentIslandDisplayPreference
  ) -> AgentIslandDisplayPreference {
    switch self {
    case .automatic:
      return .automatic
    case .display(let id):
      if let screen = screens.first(where: { $0.id == id }) {
        return .display(id: id, name: screen.name)
      }
      if case .display(let currentID, let currentName) = current, currentID == id {
        return .display(id: id, name: currentName)
      }
      return .display(id: id, name: id)
    }
  }
}

struct AgentIslandSettingsSection: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let effectiveKeybindings: ResolvedKeybindingMap
  let customCommands: [EffectiveCustomCommand]
  let globalHotKeyRegistrationFailure: Keybinding?
  @State private var silentOpacityDraft: Double?
  @State private var displayCatalog = AgentIslandDisplayCatalog.shared

  var body: some View {
    Section {
      Toggle(isOn: $store.agentIslandEnabled) {
        Text("Show Agent Island")
        Text("Working stays compact. Blocked and Done appear as stronger agent notifications.")
      }
      .help("Show active agent status at the top of the selected display")
      Picker(selection: displaySelection) {
        Text("Automatic").tag(AgentIslandDisplaySelection.automatic)
        ForEach(displayCatalog.screens) { screen in
          Text(screen.name).tag(AgentIslandDisplaySelection.display(id: screen.id))
        }
        if let disconnected = disconnectedPinnedDisplay {
          Text(disconnected.name).tag(AgentIslandDisplaySelection.display(id: disconnected.id))
        }
      } label: {
        Text("Monitor")
        Text(displayCaption)
      }
      .help("Choose the built-in or external monitor that shows Agent Island")
      .disabled(!store.agentIslandEnabled)

      ShortcutSettingsEditor(
        store: store,
        effectiveKeybindings: effectiveKeybindings,
        customCommands: customCommands,
        islandHotKeyRegistrationFailure: globalHotKeyRegistrationFailure,
        commandID: AppShortcuts.CommandID.toggleAgentIsland
      )
      Text(ShortcutSettingsEditor.globalShortcutHelp)
        .font(.callout)
        .foregroundStyle(.secondary)

      LabeledContent {
        HStack(spacing: 8) {
          Slider(
            value: Binding(
              get: { silentOpacityDraft ?? store.agentIslandSilentOpacity },
              set: { silentOpacityDraft = $0 }
            ),
            in: AgentIslandOpacityPolicy.minimumSilentOpacity...AgentIslandOpacityPolicy.maximumSilentOpacity,
            step: 0.05,
            onEditingChanged: { isEditing in
              if !isEditing { commitSilentOpacity() }
            }
          )
          .frame(width: 140)
          .accessibilityLabel("Silent opacity")
          Text("\(Int(((silentOpacityDraft ?? store.agentIslandSilentOpacity) * 100).rounded()))%")
            .monospacedDigit()
            .frame(width: 40, alignment: .trailing)
        }
      } label: {
        Text("Silent Opacity")
        Text("Monitors without a notch only. Fades after three seconds without hover or strong reminders.")
      }
      .help("Set the floating island's opacity while quiet; notched monitors always stay fully opaque")
      .onDisappear { commitSilentOpacity() }

      LabeledContent {
        Button("Reset") {
          store.send(.resetIslandFloatingPositionsTapped)
        }
        .disabled(store.agentIslandFloatingPositions.isEmpty)
      } label: {
        Text("Floating Positions")
        Text("Centers Agent Island on displays without a notch.")
      }
      .help("Reset Agent Island's saved floating positions")
    } header: {
      Text("Agent Island")
    }
  }

  private func commitSilentOpacity() {
    guard let silentOpacityDraft else { return }
    self.silentOpacityDraft = nil
    guard silentOpacityDraft != store.agentIslandSilentOpacity else { return }
    store.send(.setAgentIslandSilentOpacity(silentOpacityDraft))
  }

  private var displaySelection: Binding<AgentIslandDisplaySelection> {
    let preference = $store.agentIslandDisplayPreference
    return Binding(
      get: { AgentIslandDisplaySelection(preference.wrappedValue) },
      set: { selection in
        preference.wrappedValue = selection.preference(
          screens: displayCatalog.screens,
          current: preference.wrappedValue
        )
      }
    )
  }

  /// A pinned display that is not connected right now stays listed under its last-known name
  /// so the selection survives until it returns.
  private var disconnectedPinnedDisplay: (id: String, name: String)? {
    guard
      case .display(let id, let name) = store.agentIslandDisplayPreference,
      !displayCatalog.screens.contains(where: { $0.id == id })
    else { return nil }
    return (id, name)
  }

  private var displayCaption: String {
    switch store.agentIslandDisplayPreference {
    case .automatic:
      return "With external monitors connected, follows the monitor containing Prowl's main window."
    case .display(let id, let name):
      if let screen = displayCatalog.screens.first(where: { $0.id == id }) {
        return "Shows only on \(screen.name), even when Prowl moves to another monitor."
      }
      return "\(name) is disconnected. Using Automatic until it returns."
    }
  }
}
