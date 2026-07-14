import Testing

@testable import supacode

struct CommandIconMapTests {
  // MARK: - First-token resolution

  @Test func resolvesExactToken() throws {
    let icon = try #require(CommandIconMap.iconForFirstToken("git"))
    #expect(icon.systemSymbol == "arrow.triangle.branch")
    #expect(icon.assetName == "Git")
  }

  @Test func resolvesByFirstTokenWithArgs() {
    // "git status" should match the `git` entry, not look up "git status".
    #expect(CommandIconMap.iconForFirstToken("git status")?.assetName == "Git")
    #expect(CommandIconMap.iconForFirstToken("swift build --release")?.assetName == "Swift")
    #expect(CommandIconMap.iconForFirstToken("docker compose up -d")?.assetName == "Docker")
  }

  @Test func lookupIsCaseInsensitive() {
    #expect(CommandIconMap.iconForFirstToken("GIT")?.assetName == "Git")
    #expect(CommandIconMap.iconForFirstToken("Docker")?.assetName == "Docker")
    #expect(CommandIconMap.iconForFirstToken("CLAUDE")?.assetName == "ClaudeCode")
  }

  @Test func returnsNilForUnknownToken() {
    #expect(CommandIconMap.iconForFirstToken("never-heard-of-this-cli") == nil)
    #expect(CommandIconMap.iconForFirstToken("xyzzy") == nil)
  }

  @Test func returnsNilForEmptyTitle() {
    #expect(CommandIconMap.iconForFirstToken("") == nil)
  }

  @Test func handlesLeadingWhitespace() {
    // `split(omittingEmpty:)` skips the leading space so the first
    // real token still resolves.
    #expect(CommandIconMap.iconForFirstToken("  git status")?.assetName == "Git")
  }

  // MARK: - Aliases reuse the right asset

  @Test func packageManagerAliasesShareAssets() {
    // Runners share the icon of their parent package manager.
    #expect(CommandIconMap.iconForFirstToken("npx")?.assetName == "Npm")
    #expect(CommandIconMap.iconForFirstToken("bunx")?.assetName == "Bun")
    #expect(CommandIconMap.iconForFirstToken("pip")?.assetName == "Python")
    #expect(CommandIconMap.iconForFirstToken("pip3")?.assetName == "Python")
  }

  @Test func tuiFrontendsShareAssets() {
    // lazygit/lazydocker are TUI frontends — share the icon.
    #expect(CommandIconMap.iconForFirstToken("lazygit")?.assetName == "Git")
    #expect(CommandIconMap.iconForFirstToken("lazydocker")?.assetName == "Docker")
  }

  @Test func pythonAliasMapsToPython() {
    #expect(CommandIconMap.iconForFirstToken("python")?.assetName == "Python")
    #expect(CommandIconMap.iconForFirstToken("python3")?.assetName == "Python")
  }

  // MARK: - Coding agents

  @Test func codingAgentsResolved() {
    #expect(CommandIconMap.iconForFirstToken("omp")?.assetName == "OMP")
    #expect(CommandIconMap.iconForFirstToken("oh-my-pi")?.assetName == "OMP")
    // Sample of the coding-agent set — they all share the sparkle SF
    // Symbol fallback, asset names match the imageset folders.
    #expect(CommandIconMap.iconForFirstToken("agent")?.assetName == "Cursor")
    #expect(CommandIconMap.iconForFirstToken("claude")?.assetName == "ClaudeCode")
    #expect(CommandIconMap.iconForFirstToken("codex")?.assetName == "Codex")
    #expect(CommandIconMap.iconForFirstToken("gemini")?.assetName == "Gemini")
    #expect(CommandIconMap.iconForFirstToken("grok")?.assetName == "Grok")
    #expect(CommandIconMap.iconForFirstToken("copilot")?.assetName == "GitHubCopilot")
    #expect(CommandIconMap.iconForFirstToken("pi")?.assetName == "Pi")
    #expect(CommandIconMap.iconForFirstToken("cursor")?.assetName == "Cursor")
    #expect(CommandIconMap.iconForFirstToken("cursor-agent")?.assetName == "Cursor")
    #expect(CommandIconMap.iconForFirstToken("cline")?.assetName == "Cline")
    #expect(CommandIconMap.iconForFirstToken("droid")?.assetName == "Droid")
    #expect(CommandIconMap.iconForFirstToken("qwen")?.assetName == "Qwen")
    // Aider has no bundled brand asset — sparkle fallback only.
    #expect(CommandIconMap.iconForFirstToken("aider")?.systemSymbol == "sparkle")
    #expect(CommandIconMap.iconForFirstToken("aider")?.assetName == nil)
  }

  @Test func allDetectedAgentsResolveToIcons() {
    for agent in DetectedAgent.allCases {
      #expect(CommandIconMap.iconForFirstToken(agent.iconLookupToken) != nil)
    }
  }

  // MARK: - Debug catalog

  @Test func debugAllEntriesIsSorted() {
    let tokens = CommandIconMap.debugAllEntries.map(\.token)
    #expect(tokens == tokens.sorted())
  }

  @Test func debugAllEntriesCoversWellKnownTokens() {
    let tokens = Set(CommandIconMap.debugAllEntries.map(\.token))
    // Spot-check that the debug surface actually exposes the tokens
    // a user is most likely to hunt for.
    let mustHave: Set<String> = [
      "git", "docker", "claude", "vim", "ssh", "npm", "swift",
    ]
    #expect(mustHave.isSubset(of: tokens))
  }
}
