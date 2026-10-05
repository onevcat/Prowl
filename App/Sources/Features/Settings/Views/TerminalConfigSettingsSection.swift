import AppKit
import ComposableArchitecture
import SwiftUI

/// Chooses the Ghostty config file that Prowl's terminals use.
struct TerminalConfigSettingsSection: View {
  @Bindable var store: StoreOf<SettingsFeature>
  /// Bumped after Open Config may have created the file, so the missing-file
  /// notice is evaluated again.
  @State private var fileCheckGeneration = 0

  var body: some View {
    let source = GhosttyConfigSource(dedicatedPath: store.ghosttyConfigPath)
    Section("Terminal Config") {
      LabeledContent("Ghostty config") {
        if let path = store.ghosttyConfigPath {
          Text(path)
            .monospaced()
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(path)
        } else {
          Text("Shared with Ghostty")
            .help("Prowl reads the same config files as the standalone Ghostty app.")
        }
      }
      HStack(spacing: 8) {
        Button("Choose File…") {
          presentConfigFilePicker()
        }
        .help("Use a separate Ghostty config file for Prowl only. Ghostty's own config files are then ignored.")
        if store.ghosttyConfigPath != nil {
          Button("Use Ghostty's Config") {
            store.send(.setGhosttyConfigPath(nil))
          }
          .help("Read the config files of the standalone Ghostty app again.")
        }
        Spacer()
        Button("Open Config") {
          GhosttyRuntime.openGhosttyConfig(source: source)
          fileCheckGeneration += 1
        }
        .help("Open the Ghostty config file that Prowl uses in the default text editor.")
        Button("Reload") {
          GhosttyRuntime.shared?.reloadAppConfig()
          fileCheckGeneration += 1
        }
        .help("Read the Ghostty config from disk again and apply it to running terminals.")
      }
      if isMissing(source, generation: fileCheckGeneration) {
        Label(
          "The file does not exist. Terminals use Ghostty's built-in defaults until you create it.",
          systemImage: "exclamationmark.triangle"
        )
        .symbolRenderingMode(.multicolor)
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
  }

  // `generation` only makes SwiftUI evaluate the check again after a button
  // may have changed the file system.
  private func isMissing(_ source: GhosttyConfigSource, generation _: Int) -> Bool {
    guard case .file(let path) = source else { return false }
    return !FileManager.default.fileExists(atPath: path)
  }

  private func presentConfigFilePicker() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    if let path = store.ghosttyConfigPath {
      panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
    }
    panel.prompt = String(localized: "Use for Prowl")
    panel.message = String(
      localized: "Choose a Ghostty config file for Prowl. Ghostty's own config files will be ignored."
    )
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      store.send(.setGhosttyConfigPath(url.path(percentEncoded: false)))
    }
  }
}
