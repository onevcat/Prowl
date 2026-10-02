import Foundation

/// Resolves a tab icon from a command title surfaced by the
/// auto-detector (typically the OSC 2 title set by the shell's
/// `preexec`).
///
/// Lookup is case-insensitive on the *first whitespace-delimited
/// token*. Examples: `"swift build"` and `"swift test"` route through
/// the `swift` entry; `"claude"` routes through `claude`.
///
/// Returns `nil` when nothing matches; the auto-detector then leaves
/// the tab's existing icon untouched (selection-2 semantics — a
/// previously-detected icon is preserved across unknown commands).
enum CommandIconMap {
  static func iconForFirstToken(_ title: String) -> TabIconSource? {
    let token = firstToken(of: title).lowercased()
    return firstTokenMapping[token]
  }

  private static func firstToken(of title: String) -> String {
    title
      .split(separator: " ", omittingEmptySubsequences: true)
      .first
      .map(String.init)
      ?? title
  }

  /// First-token table. Grouped by category and alphabetised within
  /// each group. SF Symbols only at this layer keep things glanceable
  /// before asset rendering is wired; entries that ship branded
  /// artwork should add `assetName:` and let renderers prefer it.
  private static let firstTokenMapping: [String: TabIconSource] = [
    // Coding agents
    "aider": TabIconSource(systemSymbol: "sparkle"),
    "agent": TabIconSource(systemSymbol: "sparkle", assetName: "Cursor"),
    "amp": TabIconSource(systemSymbol: "sparkle", assetName: "Amp"),
    "claude": TabIconSource(systemSymbol: "sparkle", assetName: "ClaudeCode"),
    "cline": TabIconSource(systemSymbol: "sparkle", assetName: "Cline"),
    "codex": TabIconSource(systemSymbol: "sparkle", assetName: "Codex"),
    "copilot": TabIconSource(systemSymbol: "sparkle", assetName: "GitHubCopilot"),
    "cursor": TabIconSource(systemSymbol: "sparkle", assetName: "Cursor"),
    "cursor-agent": TabIconSource(systemSymbol: "sparkle", assetName: "Cursor"),
    "droid": TabIconSource(systemSymbol: "sparkle", assetName: "Droid"),
    "gemini": TabIconSource(systemSymbol: "sparkle", assetName: "Gemini"),
    "kimi": TabIconSource(systemSymbol: "sparkle", assetName: "Kimi"),
    "opencode": TabIconSource(systemSymbol: "sparkle", assetName: "OpenCode"),
    "qodercli": TabIconSource(systemSymbol: "sparkle"),
    "qwen": TabIconSource(systemSymbol: "sparkle", assetName: "Qwen"),
    "grok": TabIconSource(systemSymbol: "sparkle", assetName: "Grok"),
    "omp": TabIconSource(systemSymbol: "sparkle", assetName: "OMP"),
    "oh-my-pi": TabIconSource(systemSymbol: "sparkle", assetName: "OMP"),
    "pi": TabIconSource(systemSymbol: "sparkle", assetName: "Pi"),

    // Editors / IDEs / pagers
    "vim": TabIconSource(systemSymbol: "pencil.and.scribble", assetName: "Vim"),
    "nvim": TabIconSource(systemSymbol: "pencil.and.scribble", assetName: "Neovim"),
    "nano": TabIconSource(systemSymbol: "pencil.and.scribble"),
    "code": TabIconSource(
      systemSymbol: "chevron.left.forwardslash.chevron.right",
      assetName: "VSCode"
    ),

    // Package managers / runners — `npx` and `bunx` are the
    // ad-hoc-package execution counterparts to `npm` and `bun`,
    // share the icons. `pip` is Python's package manager and rides
    // on the Python asset.
    "npm": TabIconSource(systemSymbol: "shippingbox", assetName: "Npm"),
    "npx": TabIconSource(systemSymbol: "shippingbox", assetName: "Npm"),
    "pnpm": TabIconSource(systemSymbol: "shippingbox", assetName: "Pnpm"),
    "yarn": TabIconSource(systemSymbol: "shippingbox", assetName: "Yarn"),
    "bun": TabIconSource(systemSymbol: "shippingbox", assetName: "Bun"),
    "bunx": TabIconSource(systemSymbol: "shippingbox", assetName: "Bun"),
    "brew": TabIconSource(systemSymbol: "shippingbox", assetName: "Homebrew"),
    "pip": TabIconSource(systemSymbol: "shippingbox", assetName: "Python"),
    "pip3": TabIconSource(systemSymbol: "shippingbox", assetName: "Python"),

    // Runtime / version managers
    "mise": TabIconSource(systemSymbol: "arrow.up.arrow.down"),

    // Languages / runtimes
    "node": TabIconSource(systemSymbol: "terminal", assetName: "Node"),
    "go": TabIconSource(systemSymbol: "terminal", assetName: "Go"),
    "deno": TabIconSource(systemSymbol: "terminal", assetName: "Deno"),
    "python": TabIconSource(systemSymbol: "terminal", assetName: "Python"),
    "python3": TabIconSource(systemSymbol: "terminal", assetName: "Python"),

    // Terminal multiplexers
    "tmux": TabIconSource(systemSymbol: "rectangle.split.3x1", assetName: "Tmux"),

    // VCS — `lazygit` is a TUI front-end for git, share the icon.
    "git": TabIconSource(systemSymbol: "arrow.triangle.branch", assetName: "Git"),
    "gh": TabIconSource(systemSymbol: "arrow.triangle.branch", assetName: "GitHub"),
    "lazygit": TabIconSource(systemSymbol: "arrow.triangle.branch", assetName: "Git"),

    // Build tools
    "make": TabIconSource(systemSymbol: "hammer"),
    "swift": TabIconSource(systemSymbol: "hammer", assetName: "Swift"),
    "cargo": TabIconSource(systemSymbol: "hammer", assetName: "Rust"),
    "xcodebuild": TabIconSource(systemSymbol: "hammer", assetName: "Xcode"),
    "gradle": TabIconSource(systemSymbol: "hammer", assetName: "Gradle"),
    "tsc": TabIconSource(systemSymbol: "hammer", assetName: "TypeScript"),

    // Container / orchestration — `lazydocker` is a TUI for docker,
    // shares the icon.
    "docker": TabIconSource(systemSymbol: "shippingbox.fill", assetName: "Docker"),
    "kubectl": TabIconSource(systemSymbol: "shippingbox.fill", assetName: "Kubernetes"),
    "podman": TabIconSource(systemSymbol: "shippingbox.fill", assetName: "Podman"),
    "lazydocker": TabIconSource(systemSymbol: "shippingbox.fill", assetName: "Docker"),

    // IaC / cloud CLIs
    "terraform": TabIconSource(systemSymbol: "cloud", assetName: "Terraform"),
    "aws": TabIconSource(systemSymbol: "cloud", assetName: "AWS"),
    "az": TabIconSource(systemSymbol: "cloud", assetName: "Azure"),
    "gcloud": TabIconSource(systemSymbol: "cloud", assetName: "GoogleCloud"),

    // Network / remote
    "ssh": TabIconSource(systemSymbol: "network"),
    "mosh": TabIconSource(systemSymbol: "network"),
    "curl": TabIconSource(systemSymbol: "network", assetName: "Curl"),
    "wget": TabIconSource(systemSymbol: "arrow.down.circle"),

    // Process / system viewers
    "htop": TabIconSource(systemSymbol: "waveform.path.ecg"),
    "btop": TabIconSource(systemSymbol: "waveform.path.ecg"),
    "top": TabIconSource(systemSymbol: "waveform.path.ecg"),

    // Database REPLs
    "psql": TabIconSource(systemSymbol: "cylinder.split.1x2", assetName: "PostgreSQL"),
    "mysql": TabIconSource(systemSymbol: "cylinder.split.1x2", assetName: "MySQL"),
    "sqlite3": TabIconSource(systemSymbol: "cylinder.split.1x2", assetName: "SQLite"),

    // Logs / streams
    "tail": TabIconSource(systemSymbol: "text.justifyleft"),
    "journalctl": TabIconSource(systemSymbol: "text.justifyleft"),
  ]
}

#if DEBUG

  extension CommandIconMap {
    /// All first-token mapping entries, sorted alphabetically by
    /// token. Surfaced for the Debug Window's Icon Catalog so the
    /// auto-detected set can be eyeballed in one place.
    static var debugAllEntries: [(token: String, icon: TabIconSource)] {
      firstTokenMapping
        .map { (token: $0.key, icon: $0.value) }
        .sorted { $0.token < $1.token }
    }
  }

#endif
