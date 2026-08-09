import AppKit
import ComposableArchitecture
import SwiftUI

struct AppearanceSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    let openActionOptions = OpenWorktreeAction.availableCases
    let externalDiffToolOptions = ExternalDiffTool.settingsMenuCases
    VStack(alignment: .leading) {
      Form {
        Section("Appearance") {
          HStack {
            let appearanceMode: Binding<AppearanceMode> = $store.appearanceMode
            ForEach(AppearanceMode.allCases) { mode in
              AppearanceOptionCardView(
                mode: mode,
                isSelected: mode == appearanceMode.wrappedValue
              ) {
                appearanceMode.wrappedValue = mode
              }
            }
          }
          VStack(alignment: .leading, spacing: 6) {
            Text("Ghostty Configuration")
              .font(.headline)
              .foregroundStyle(.primary)
            Text(store.ghosttyConfigPath ?? "Using Ghostty's default configuration")
              .monospaced()
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
              .help(
                store.ghosttyConfigPath ?? "Prowl follows Ghostty's default configuration files.")
            HStack(spacing: 8) {
              Button("Choose Config…") {
                presentGhosttyConfigPicker()
              }
              .help("Choose a dedicated Ghostty configuration file for Prowl.")
              Button("Use Default") {
                store.send(.setGhosttyConfigPath(nil))
              }
              .disabled(store.ghosttyConfigPath == nil)
              .help("Stop using the override and return to Ghostty's default configuration.")
            }
            .controlSize(.small)
            Text("An override replaces the global Ghostty configuration while it is selected.")
            Text(
              """
              Terminal theming follows your Ghostty configuration. \
              Browse [all built-in themes](https://iterm2colorschemes.com/), \
              then add a dual-theme line such as:
              """
            )
            Text("theme = light:Monokai Pro Light Sun,dark:Dimmed Monokai")
              .monospaced()
              .textSelection(.enabled)
            HStack(spacing: 8) {
              Button("Open Config") {
                if let runtime = GhosttyRuntime.shared {
                  runtime.openAppConfig()
                } else {
                  GhosttyRuntime.openGhosttyConfig(at: store.ghosttyConfigPath)
                }
              }
              .help("Open the active Ghostty config file in the default text editor.")
              Button("Reload") {
                GhosttyRuntime.shared?.reloadAppConfig()
              }
              .help("Re-read the Ghostty config from disk and apply it to running terminals.")
            }
            .controlSize(.small)
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        Section("Window Tint") {
          Picker("Tint nav & toolbar", selection: $store.windowTintMode) {
            ForEach(WindowTintMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .help("Color the navigation panel and toolbar.")
          if store.windowTintMode == .custom {
            ColorPicker(
              "Custom tint color",
              selection: $store.windowTintCustomColor,
              supportsOpacity: false
            )
            .help(
              "Tint the nav and toolbar with this color in every view, ignoring repository colors.")
          }
          Text(tintFootnote)
            .font(.callout)
            .foregroundStyle(.secondary)

          Picker("Tint spines in Shelf View", selection: $store.shelfSpineTintFallback) {
            ForEach(ShelfSpineTintFallback.allCases) { fallback in
              Text(fallback.title).tag(fallback)
            }
          }
          .help(
            "Spine style for repositories without a color, or for every spine when Follow Repo Color is off."
          )
          Toggle(
            "Follow Repo Color Setting",
            isOn: $store.shelfSpineTintFollowsRepositoryColor
          )
          .help("When disabled, all Shelf spines use the selected Neutral or System Tint style.")
          Text(shelfSpineTintFootnote)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Section("Repository Icons") {
          Toggle(
            "Detect project icons automatically",
            isOn: $store.detectRepositoryIconsAutomatically
          )
          .help("Use a project's own app icon or logo as the repository icon when adding it.")
          Text(
            "Detection runs locally when a repository is added. It never replaces an icon "
              + "you picked, and turning it off leaves already detected icons unchanged."
          )
          .foregroundStyle(.secondary)
          .font(.callout)
        }
        Section("Splits") {
          Toggle(
            "Dim unfocused split panes",
            isOn: $store.dimUnfocusedSplits
          )
          .help("Fade split panes that aren't focused so the active one stands out.")
        }
        Section("Active Agents") {
          Toggle(
            "Show Active Agents panel automatically",
            isOn: $store.autoShowActiveAgentsPanel
          )
          .help("Open the Active Agents panel when an agent is detected.")
          Text("Hidden panels reopen as soon as an agent starts or updates.")
            .foregroundStyle(.secondary)
            .font(.callout)
          Toggle(
            "Show terminal titles in agent rows",
            isOn: $store.showActiveAgentTabTitles
          )
          .help(
            "Display each agent's own terminal title in the row and show the branch name on hover.")
          Toggle(
            "Show agent status in Shelf tabs",
            isOn: $store.showActiveAgentStatusInShelf
          )
          .help("Overlay detected agent status on the owning tab icon in Shelf View.")
        }
        Section("Default Views") {
          Picker("Open when launching Prowl", selection: $store.defaultViewMode) {
            ForEach(DefaultViewMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .help(
            "View Prowl starts in on launch. Shelf and Canvas require at least one worktree or folder."
          )

          Picker("Canvas layout", selection: $store.canvasDefaultLayout) {
            ForEach(CanvasDefaultLayout.allCases) { layout in
              Text(layout.title).tag(layout)
            }
          }
          .help("How cards are arranged the first time you open Canvas for a set of cards.")
          Text(store.canvasDefaultLayout.settingsDescription)
            .foregroundStyle(.secondary)
            .font(.callout)
        }
        Section("Default Editor") {
          Toggle(
            "Show in toolbar",
            isOn: $store.showDefaultEditorInToolbar
          )
          .help("Show the Open in Editor button in the worktree toolbar.")
          Picker(
            "Default editor",
            selection: $store.defaultEditorID
          ) {
            Text("Automatic")
              .tag(OpenWorktreeAction.automaticSettingsID)
            ForEach(openActionOptions) { action in
              Text(action.labelTitle)
                .tag(action.settingsID)
            }
          }
          .help(
            "Applies to worktrees without repository overrides. "
              + "Automatic prefers an app matching the project type, e.g. Xcode for Swift projects."
          )
        }
        Section("Diff Tool") {
          Picker(
            "Open diff with",
            selection: $store.externalDiffToolID
          ) {
            ForEach(externalDiffToolOptions) { tool in
              Text(tool.title)
                .tag(tool.settingsID)
                .disabled(!tool.isInstalled)
            }
          }
          .help("Choose what opens when you click a diff badge or run Show Diff.")
          Text("Tools not installed on this Mac appear disabled.")
            .font(.callout)
            .foregroundStyle(.secondary)
          if store.externalDiffToolID == ExternalDiffTool.custom.settingsID {
            TextField(
              "Command",
              text: $store.externalDiffCustomCommand,
              prompt: Text("my-diff {leftPath} {rightPath}")
            )
            .textFieldStyle(.roundedBorder)
            .help(
              "Runs in the worktree directory. Supports {leftPath}, {rightPath}, "
                + "{worktreePath}, {repoPath}, and {branch}."
            )
          }
        }
        Section("Run") {
          Toggle(
            "Show in toolbar",
            isOn: $store.showRunButtonInToolbar
          )
          .help("Show the Run button in the worktree toolbar.")
        }
        Section("Quit") {
          Toggle(
            "Confirm before quitting",
            isOn: $store.confirmBeforeQuit
          )
          .help("Ask before quitting Prowl")
        }
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func presentGhosttyConfigPicker() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Use Config"
    panel.message = "Choose the Ghostty configuration file Prowl should use."
    if let path = store.ghosttyConfigPath {
      panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
    }
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      store.send(.setGhosttyConfigPath(url.path(percentEncoded: false)))
    }
  }

  private var tintFootnote: String {
    switch store.windowTintMode {
    case .none:
      return "No tint. The nav and toolbar use the neutral system chrome."
    case .repositoryColor:
      return "Uses the active repository's color. Uncolored repositories get a neutral surface."
    case .custom:
      return "Uses your chosen color everywhere, regardless of per-repository colors."
    }
  }

  private var shelfSpineTintFootnote: String {
    let fallback =
      switch store.shelfSpineTintFallback {
      case .neutral:
        "Uncolored repositories use a neutral spine."
      case .systemTint:
        "Uncolored repositories use the system tint color."
      }

    if store.shelfSpineTintFollowsRepositoryColor {
      return fallback + " Repositories with a custom color still use that color."
    } else {
      return fallback + " Repository colors are ignored for Shelf spines."
    }
  }
}
