import ComposableArchitecture
import SwiftUI

/// The Remote Mirror tab (docs-ai 091). While the alpha switch is off, it shows the switch only.
struct RemoteMirrorSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $store.remoteMirrorEnabled) {
          HStack(spacing: 6) {
            Text("Enable Remote Mirror")
            Text("Alpha")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.quaternary, in: .capsule)
              .accessibilityLabel("Alpha feature")
          }
          Text(
            """
            See and control the Prowl terminals of this Mac from Prowl Mirror on an iPhone, or from \
            Prowl on another Mac, on the same network. This feature is in alpha and can change \
            between releases.
            """)
        }
        .help("Show the Remote Mirror button in the toolbar and let paired devices connect to this Mac")
        .accessibilityIdentifier("remote-mirror-enable")
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
