import ComposableArchitecture
import ProwlCLIShared
import SwiftUI

struct AppearanceSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    let openActionOptions = OpenWorktreeAction.availableCases
    let externalDiffToolOptions = ExternalDiffTool.settingsMenuCases
    VStack(alignment: .leading) {
      Form {
        Section {
          Picker(
            selection: Binding(
              get: { store.appLanguage },
              set: { store.send(.setAppLanguage($0)) }
            )
          ) {
            Text(AppLanguage.system.title).tag(AppLanguage.system)
            Divider()
            ForEach(AppLanguage.allCases.filter { $0 != .system }) { language in
              Text(language.title).tag(language)
            }
          } label: {
            Label("Language", systemImage: "translate")
            Text(
              "The change applies the next time Prowl starts; quitting the app may interrupt running terminal tasks.",
              comment: "App language setting footer: Restart requirement and terminal task warning"
            )
            if store.languageChangePending {
              Text("The language will switch on next launch.", comment: "App language change pending notice")
            }
          }
        }
        .help("Choose the app language. The change applies the next time Prowl starts.")
        .onAppear {
          store.send(.refreshAppLanguage)
        }
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
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        TerminalConfigSettingsSection(store: store)
        Section("Window Tint") {
          Picker(selection: $store.windowTintMode) {
            ForEach(WindowTintMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          } label: {
            Text("Tint nav & toolbar")
            Text(tintFootnote)
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

          Picker(selection: $store.shelfSpineTintFallback) {
            ForEach(ShelfSpineTintFallback.allCases) { fallback in
              Text(fallback.title).tag(fallback)
            }
          } label: {
            Text("Tint spines in Shelf View")
            Text(shelfSpineTintFallbackCaption)
          }
          .help("Spine style for repositories without a color, or for every spine when Follow Repo Color is off.")
          Toggle(isOn: $store.shelfSpineTintFollowsRepositoryColor) {
            Text("Follow Repo Color Setting")
            Text(shelfSpineTintFollowCaption)
          }
          .help("When disabled, all Shelf spines use the selected Gray or System Tint style.")
        }
        Section("Repository Icons") {
          Toggle(isOn: $store.detectRepositoryIconsAutomatically) {
            Text("Detect project icons automatically")
            Text(
              """
              Detection runs locally when a repository is added. It never replaces an icon \
              you picked, and turning it off leaves already detected icons unchanged.
              """
            )
          }
          .help("Use a project's own app icon or logo as the repository icon when adding it.")
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

          Picker(selection: $store.canvasDefaultLayout) {
            ForEach(CanvasDefaultLayout.allCases) { layout in
              Text(layout.title).tag(layout)
            }
          } label: {
            Text("Canvas layout")
            Text(store.canvasDefaultLayout.settingsDescription)
          }
          .help("How cards are arranged the first time you open Canvas for a set of cards.")
        }
        Section("Terminal Layout") {
          Toggle(isOn: $store.restoreTerminalLayoutOnLaunch) {
            Text("Restore terminal layout on launch")
            Text("Reopens your tabs and splits in their folders. Commands that were running do not start again.")
          }
          .help("Reopen the saved terminal tabs and splits when Prowl starts")
          Button("Clear saved terminal layout") {
            store.send(.clearTerminalLayoutSnapshotButtonTapped)
          }
          .help("Remove the saved terminal tab and split layout from disk")
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
            """
            Applies to worktrees without repository overrides. \
            Automatic prefers an app matching the project type, e.g. Xcode for Swift projects.
            """
          )
        }
        Section("Diff Tool") {
          Picker(selection: $store.externalDiffToolID) {
            ForEach(externalDiffToolOptions) { tool in
              Text(tool.title)
                .tag(tool.settingsID)
                .disabled(!tool.isInstalled)
            }
          } label: {
            Text("Open diff with")
            Text("Tools not installed on this Mac appear disabled.")
          }
          .help("Choose what opens when you click a diff badge or run Show Diff.")
          if store.externalDiffToolID == ExternalDiffTool.custom.settingsID {
            TextField(
              "Command",
              text: $store.externalDiffCustomCommand,
              prompt: Text("my-diff {leftPath} {rightPath}")
            )
            .textFieldStyle(.roundedBorder)
            .help(
              """
              Runs in the worktree directory. Supports {leftPath}, {rightPath}, \
              {worktreePath}, {repoPath}, and {branch}.
              """
            )
          }
          Toggle(
            "Show change counts in the sidebar",
            isOn: $store.showSidebarChangeCounts
          )
          .help("Show the added and removed line counts on sidebar rows. Show Diff still works when they are hidden.")
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
      return String(localized: "No tint. The nav and toolbar use the default system look.")
    case .repositoryColor:
      return String(localized: "Uses the active repository's color. Uncolored repositories use gray.")
    case .custom:
      return String(localized: "Uses your chosen color everywhere, regardless of per-repository colors.")
    }
  }

  private var shelfSpineTintFallbackCaption: String {
    switch store.shelfSpineTintFallback {
    case .neutral:
      return String(localized: "Uncolored repositories use a gray spine.")
    case .systemTint:
      return String(localized: "Uncolored repositories use the system tint color.")
    }
  }

  private var shelfSpineTintFollowCaption: String {
    store.shelfSpineTintFollowsRepositoryColor
      ? String(localized: "Repositories with a custom color still use that color.")
      : String(localized: "Repository colors are ignored for Shelf spines.")
  }
}
