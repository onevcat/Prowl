import ComposableArchitecture
import SwiftUI

struct AppearanceSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    let openActionOptions = OpenWorktreeAction.availableCases
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
        Section("Splits") {
          Toggle(
            "Dim unfocused split panes",
            isOn: $store.dimUnfocusedSplits
          )
          .help("Fade split panes that aren't focused so the active one stands out.")
        }
        Section("Canvas") {
          Toggle(
            "Adapt card size to display",
            isOn: $store.useAdaptiveCanvasCardSize
          )
          .help(
            "When disabled, new and organized Canvas cards use the fixed custom size: 800x710 including the title bar.")
        }
        Section("Active Agents") {
          Toggle(
            "Auto-manage Active Agents panel in Canvas",
            isOn: $store.autoShowActiveAgentsPanel
          )
          .help(
            "Show the Active Agents panel in Canvas while agents are active, then hide it when none remain."
          )
          Text("Normal and Shelf keep the panel under manual control.")
            .foregroundStyle(.secondary)
            .font(.callout)
          Toggle(
            "Show tab titles in agent rows",
            isOn: $store.showActiveAgentTabTitles
          )
          .help("Display each agent's tab title in the row and show the branch name on hover.")
          Toggle(
            "Show agent status in Shelf tabs",
            isOn: $store.showActiveAgentStatusInShelf
          )
          .help("Overlay detected agent status on the owning tab icon in Shelf View.")
        }
        Section("Default View") {
          Picker("Launch in", selection: $store.defaultViewMode) {
            ForEach(DefaultViewMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .help(
            "Mode Prowl enters on the next launch. Shelf and Canvas require a worktree or folder; Clean starts a standalone shell."
          )
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
