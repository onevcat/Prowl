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
            let appearanceMode = $store.appearanceMode
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
                GhosttyRuntime.openGhosttyConfig()
              }
              .help("Open your Ghostty config file in the default text editor.")
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
            .help("Tint the nav and toolbar with this color in every view, ignoring repository colors.")
          }
          Text(tintFootnote)
            .font(.callout)
            .foregroundStyle(.secondary)

          Picker("Tint spines in Shelf View", selection: $store.shelfSpineTintFallback) {
            ForEach(ShelfSpineTintFallback.allCases) { fallback in
              Text(fallback.title).tag(fallback)
            }
          }
          .help("Spine style for repositories without a color, or for every spine when Follow Repo Color is off.")
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
        Section("Default Views") {
          Picker("Open when launching Prowl", selection: $store.defaultViewMode) {
            ForEach(DefaultViewMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .help("View Prowl starts in on launch. Shelf and Canvas require at least one worktree or folder.")

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
