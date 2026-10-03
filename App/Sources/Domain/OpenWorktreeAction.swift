import AppKit

enum OpenWorktreeAction: CaseIterable, Identifiable {
  enum MenuIcon {
    case app(NSImage)
    case symbol(String)
  }

  case alacritty
  case androidStudio
  case antigravity
  case clion
  case editor
  case finder
  case cursor
  case githubDesktop
  case fork
  case gitkraken
  case gitup
  case ghostty
  case goland
  case intellij
  case intellijEAP
  case iterm2
  case kitty
  case nova
  case phpstorm
  case pycharm
  case rider
  case rubymine
  case rustrover
  case smartgit
  case sourcetree
  case sublimeMerge
  case sublimeText
  case terminal
  case tower
  case vscode
  case vscodeInsiders
  case vscodium
  case warp
  case webstorm
  case wezterm
  case windsurf
  case xcode
  case zed
  case zedPreview

  var id: String {
    switch self {
    case .finder: "Open Finder"
    default: title
    }
  }

  var title: String {
    switch self {
    case .finder: String(localized: "Open Finder")
    case .editor: "$EDITOR"
    case .alacritty: "Alacritty"
    case .androidStudio: "Android Studio"
    case .antigravity: "Antigravity"
    case .clion: "CLion"
    case .cursor: "Cursor"
    case .githubDesktop: "GitHub Desktop"
    case .gitkraken: "GitKraken"
    case .gitup: "GitUp"
    case .ghostty: "Ghostty"
    case .goland: "GoLand"
    case .intellij: "IntelliJ IDEA"
    case .intellijEAP: "IntelliJ IDEA EAP"
    case .iterm2: "iTerm2"
    case .kitty: "Kitty"
    case .nova: "Nova"
    case .phpstorm: "PhpStorm"
    case .pycharm: "PyCharm"
    case .rider: "Rider"
    case .rubymine: "RubyMine"
    case .rustrover: "RustRover"
    case .smartgit: "SmartGit"
    case .sourcetree: "Sourcetree"
    case .sublimeMerge: "Sublime Merge"
    case .sublimeText: "Sublime Text"
    case .terminal: "Terminal"
    case .tower: "Tower"
    case .vscode: "VS Code"
    case .vscodeInsiders: "VS Code Insiders"
    case .vscodium: "VSCodium"
    case .warp: "Warp"
    case .wezterm: "WezTerm"
    case .webstorm: "WebStorm"
    case .windsurf: "Windsurf"
    case .xcode: "Xcode"
    case .fork: "Fork"
    case .zed: "Zed"
    case .zedPreview: "Zed Preview"
    }
  }

  var labelTitle: String {
    switch self {
    case .finder: "Finder"
    case .editor: "$EDITOR"
    case .alacritty, .androidStudio, .antigravity, .clion, .cursor, .fork, .githubDesktop, .gitkraken,
      .gitup, .ghostty, .goland, .intellij, .intellijEAP, .iterm2, .kitty, .nova, .phpstorm, .pycharm,
      .rider, .rubymine, .rustrover, .smartgit, .sourcetree, .sublimeMerge, .sublimeText, .terminal,
      .tower, .vscode, .vscodeInsiders, .vscodium, .warp, .webstorm, .wezterm, .windsurf, .xcode, .zed,
      .zedPreview:
      title
    }
  }

  // Pre-rendered at display size and cached: `icon(forFile:)` plus the
  // rasterizing resize cost milliseconds, and toolbar redraws request these
  // icons constantly. Only hits are cached so a newly installed app shows up
  // without invalidation; lookup misses are microseconds.
  private static let menuIconSize = CGSize(width: 18, height: 18)
  // `@MainActor` makes the cache's isolation explicit and compiler-enforced:
  // every `menuIcon` access happens during SwiftUI rendering on the main
  // thread, so this shared mutable state is never touched concurrently. (A
  // lock would be the wrong tool here — `NSImage` isn't `Sendable`, so the
  // cached values shouldn't cross threads in the first place.)
  @MainActor private static var menuIconCache: [String: MenuIcon] = [:]

  var menuIcon: MenuIcon? {
    switch self {
    case .editor:
      return .symbol("apple.terminal")
    default:
      if let cached = Self.menuIconCache[bundleIdentifier] {
        return cached
      }
      guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
      else { return nil }
      let icon = Self.resizedIcon(NSWorkspace.shared.icon(forFile: appURL.path), size: Self.menuIconSize)
      let menuIcon = MenuIcon.app(icon)
      Self.menuIconCache[bundleIdentifier] = menuIcon
      return menuIcon
    }
  }

  private static func resizedIcon(_ image: NSImage, size: CGSize) -> NSImage {
    let newImage = NSImage(size: size)
    newImage.lockFocus()
    image.draw(
      in: NSRect(origin: .zero, size: size),
      from: NSRect(origin: .zero, size: image.size),
      operation: .sourceOver,
      fraction: 1.0
    )
    newImage.unlockFocus()
    return newImage
  }

  var isInstalled: Bool {
    switch self {
    case .finder, .editor:
      return true
    case .alacritty, .androidStudio, .antigravity, .clion, .cursor, .fork, .githubDesktop, .gitkraken,
      .gitup, .ghostty, .goland, .intellij, .intellijEAP, .iterm2, .kitty, .nova, .phpstorm, .pycharm,
      .rider, .rubymine, .rustrover, .smartgit, .sourcetree, .sublimeMerge, .sublimeText, .terminal,
      .tower, .vscode, .vscodeInsiders, .vscodium, .warp, .webstorm, .wezterm, .windsurf, .xcode, .zed,
      .zedPreview:
      return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
  }

  var settingsID: String {
    switch self {
    case .finder: "finder"
    case .editor: "editor"
    case .alacritty: "alacritty"
    case .androidStudio: "android-studio"
    case .antigravity: "antigravity"
    case .clion: "clion"
    case .cursor: "cursor"
    case .fork: "fork"
    case .githubDesktop: "github-desktop"
    case .gitkraken: "gitkraken"
    case .gitup: "gitup"
    case .ghostty: "ghostty"
    case .goland: "goland"
    case .intellij: "intellij"
    case .intellijEAP: "intellijEAP"
    case .iterm2: "iterm2"
    case .kitty: "kitty"
    case .nova: "nova"
    case .phpstorm: "phpstorm"
    case .pycharm: "pycharm"
    case .rider: "rider"
    case .rubymine: "rubymine"
    case .rustrover: "rustrover"
    case .smartgit: "smartgit"
    case .sourcetree: "sourcetree"
    case .sublimeMerge: "sublime-merge"
    case .sublimeText: "sublime-text"
    case .terminal: "terminal"
    case .tower: "tower"
    case .vscode: "vscode"
    case .vscodeInsiders: "vscode-insiders"
    case .vscodium: "vscodium"
    case .warp: "warp"
    case .webstorm: "webstorm"
    case .wezterm: "wezterm"
    case .windsurf: "windsurf"
    case .xcode: "xcode"
    case .zed: "zed"
    case .zedPreview: "zed-preview"
    }
  }

  var bundleIdentifier: String {
    switch self {
    case .finder: "com.apple.finder"
    case .editor: ""
    case .alacritty: "org.alacritty"
    case .androidStudio: "com.google.android.studio"
    case .antigravity: "com.google.antigravity"
    case .clion: "com.jetbrains.CLion"
    case .cursor: "com.todesktop.230313mzl4w4u92"
    case .fork: "com.DanPristupov.Fork"
    case .githubDesktop: "com.github.GitHubClient"
    case .gitkraken: "com.axosoft.gitkraken"
    case .gitup: "co.gitup.mac"
    case .ghostty: "com.mitchellh.ghostty"
    case .goland: "com.jetbrains.goland"
    case .intellij: "com.jetbrains.intellij"
    case .intellijEAP: "com.jetbrains.intellij-EAP"
    case .iterm2: "com.googlecode.iterm2"
    case .kitty: "net.kovidgoyal.kitty"
    case .nova: "com.panic.Nova"
    case .phpstorm: "com.jetbrains.PhpStorm"
    case .pycharm: "com.jetbrains.pycharm"
    case .rider: "com.jetbrains.rider"
    case .rubymine: "com.jetbrains.rubymine"
    case .rustrover: "com.jetbrains.rustrover"
    case .smartgit: "com.syntevo.smartgit"
    case .sourcetree: "com.torusknot.SourceTreeNotMAS"
    case .sublimeMerge: "com.sublimemerge"
    case .sublimeText: "com.sublimetext.4"
    case .terminal: "com.apple.Terminal"
    case .tower: "com.fournova.Tower3"
    case .vscode: "com.microsoft.VSCode"
    case .vscodeInsiders: "com.microsoft.VSCodeInsiders"
    case .vscodium: "com.vscodium"
    case .warp: "dev.warp.Warp-Stable"
    case .webstorm: "com.jetbrains.WebStorm"
    case .wezterm: "com.github.wez.wezterm"
    case .windsurf: "com.exafunction.windsurf"
    case .xcode: "com.apple.dt.Xcode"
    case .zed: "dev.zed.Zed"
    case .zedPreview: "dev.zed.Zed-Preview"
    }
  }

  nonisolated static let automaticSettingsID = "auto"

  static let editorPriority: [OpenWorktreeAction] = [
    .cursor,
    .zed,
    .zedPreview,
    .vscode,
    .windsurf,
    .vscodeInsiders,
    .vscodium,
    .sublimeText,
    .nova,
    .androidStudio,
    .intellij,
    .intellijEAP,
    .webstorm,
    .pycharm,
    .rustrover,
    .rider,
    .goland,
    .clion,
    .phpstorm,
    .rubymine,
    .antigravity,
  ]
  static let terminalPriority: [OpenWorktreeAction] = [
    .ghostty,
    .wezterm,
    .alacritty,
    .kitty,
    .warp,
    .iterm2,
    .terminal,
  ]
  static let gitClientPriority: [OpenWorktreeAction] = [
    .githubDesktop,
    .sourcetree,
    .fork,
    .tower,
    .gitkraken,
    .sublimeMerge,
    .smartgit,
    .gitup,
  ]
  static let defaultPriority: [OpenWorktreeAction] =
    editorPriority + [.xcode, .finder] + terminalPriority + gitClientPriority
  static let menuOrder: [OpenWorktreeAction] =
    editorPriority + [.xcode] + [.finder] + terminalPriority + gitClientPriority + [.editor]

  static func normalizedDefaultEditorID(_ settingsID: String?) -> String {
    guard let settingsID, settingsID != automaticSettingsID else {
      return automaticSettingsID
    }
    guard let action = allCases.first(where: { $0.settingsID == settingsID }),
      action.isInstalled
    else {
      return automaticSettingsID
    }
    return settingsID
  }

  static func fromSettingsID(
    _ settingsID: String?,
    defaultEditorID: String?,
    workingDirectory: URL? = nil
  ) -> OpenWorktreeAction {
    if let settingsID, settingsID != automaticSettingsID,
      let action = allCases.first(where: { $0.settingsID == settingsID })
    {
      return action
    }
    let normalizedDefaultEditorID = normalizedDefaultEditorID(defaultEditorID)
    if normalizedDefaultEditorID != automaticSettingsID,
      let action = allCases.first(where: { $0.settingsID == normalizedDefaultEditorID })
    {
      return action
    }
    return preferredDefault(for: workingDirectory)
  }

  static var availableCases: [OpenWorktreeAction] {
    menuOrder.filter(\.isInstalled)
  }

  static func availableSelection(_ selection: OpenWorktreeAction) -> OpenWorktreeAction {
    selection.isInstalled ? selection : preferredDefault()
  }

  static func preferredDefault() -> OpenWorktreeAction {
    preferredDefault(for: nil)
  }

  /// Resolves the automatic open action. When a working directory is given,
  /// apps suited to the detected project kind (e.g. Xcode for Swift packages,
  /// Android Studio for Gradle projects) are tried before the generic priority.
  static func preferredDefault(
    for workingDirectory: URL?,
    isInstalled: (OpenWorktreeAction) -> Bool = { $0.isInstalled }
  ) -> OpenWorktreeAction {
    let projectActions =
      workingDirectory
      .flatMap { WorktreeProjectKind.detect(at: $0) }?
      .preferredActions ?? []
    return (projectActions + defaultPriority).first(where: isInstalled) ?? .finder
  }

  func perform(with worktree: Worktree, onError: @escaping @MainActor @Sendable (OpenActionError) -> Void) {
    let actionTitle = title
    switch self {
    case .editor:
      return
    case .finder:
      NSWorkspace.shared.activateFileViewerSelecting([worktree.workingDirectory])
    // Apps that require CLI arguments instead of Apple Events to open directories.
    case .androidStudio, .clion, .goland, .intellij, .intellijEAP, .phpstorm, .pycharm, .rider,
      .rubymine, .rustrover, .webstorm:
      guard
        let appURL = NSWorkspace.shared.urlForApplication(
          withBundleIdentifier: bundleIdentifier
        )
      else {
        onError(
          OpenActionError(
            title: String(localized: "\(title) not found"),
            message: String(localized: "Install \(title) to open this worktree.")
          )
        )
        return
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.createsNewApplicationInstance = true
      configuration.arguments = [worktree.workingDirectory.path]
      NSWorkspace.shared.openApplication(
        at: appURL,
        configuration: configuration
      ) { _, error in
        guard let error else { return }
        Task { @MainActor in
          onError(
            OpenActionError(
              title: String(localized: "Unable to open in \(actionTitle)"),
              message: error.localizedDescription
            )
          )
        }
      }
    case .alacritty, .antigravity, .cursor, .fork, .githubDesktop, .gitkraken, .gitup, .ghostty,
      .iterm2, .kitty, .nova, .smartgit, .sourcetree, .sublimeMerge, .sublimeText, .terminal, .tower,
      .vscode, .vscodeInsiders, .vscodium, .warp, .wezterm, .windsurf, .xcode, .zed, .zedPreview:
      guard
        let appURL = NSWorkspace.shared.urlForApplication(
          withBundleIdentifier: bundleIdentifier
        )
      else {
        onError(
          OpenActionError(
            title: String(localized: "\(title) not found"),
            message: String(localized: "Install \(title) to open this worktree.")
          )
        )
        return
      }
      let configuration = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.open(
        [worktree.workingDirectory],
        withApplicationAt: appURL,
        configuration: configuration
      ) { _, error in
        guard let error else { return }
        Task { @MainActor in
          onError(
            OpenActionError(
              title: String(localized: "Unable to open in \(actionTitle)"),
              message: error.localizedDescription
            )
          )
        }
      }
    }
  }
}
