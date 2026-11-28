import Foundation
import Testing

@testable import Prowl

struct AgentModelCatalogTests {
  // MARK: - Codex

  @Test func codexCatalogListsVisibleModelsInPriorityOrder() throws {
    let json = """
      {"models": [
        {"slug": "gpt-b", "visibility": "list", "priority": 2,
         "supported_reasoning_levels": [{"effort": "low"}, {"effort": "max"}]},
        {"slug": "gpt-hidden", "visibility": "hide", "priority": 1},
        {"slug": "gpt-a", "visibility": "list", "priority": 1,
         "supported_reasoning_levels": [{"effort": "low"}, {"effort": "ultra"}]}
      ]}
      """
    let catalog = try #require(AgentModelCatalog.parseCodex(Data(json.utf8)))
    #expect(catalog.primary.map(\.id) == ["gpt-a", "gpt-b"])
    #expect(catalog.overflow.isEmpty)
    #expect(catalog.source == .installedAgent)
    #expect(catalog.reasoningEfforts(for: "gpt-a") == ["low", "ultra"])
    #expect(catalog.reasoningEfforts(for: "gpt-b") == ["low", "max"])
  }

  @Test func codexCatalogMovesModelsPastThePrimaryLimitToOverflow() throws {
    let entries = (1...9).map { #"{"slug": "gpt-\#($0)", "visibility": "list", "priority": \#($0)}"# }
    let json = #"{"models": [\#(entries.joined(separator: ","))]}"#
    let catalog = try #require(AgentModelCatalog.parseCodex(Data(json.utf8)))
    #expect(catalog.primary.map(\.id) == (1...AgentModelCatalog.primaryLimit).map { "gpt-\($0)" })
    #expect(catalog.overflow.map(\.id) == ((AgentModelCatalog.primaryLimit + 1)...9).map { "gpt-\($0)" })
    #expect(catalog.reasoningEfforts(for: "gpt-1") == nil)
  }

  @Test func codexCatalogRejectsUnreadableOrEmptyData() {
    #expect(AgentModelCatalog.parseCodex(Data("not json".utf8)) == nil)
    #expect(AgentModelCatalog.parseCodex(Data(#"{"models": []}"#.utf8)) == nil)
    #expect(AgentModelCatalog.parseCodex(Data(#"{"models": [{"slug": "x", "visibility": "hide"}]}"#.utf8)) == nil)
  }

  // MARK: - Claude

  @Test func claudeCatalogPutsMainSectionFirstAndKeepsCatalogOrder() throws {
    let json = """
      {"version": 2, "fetchedAt": 10, "catalog": {"config": {"models": [
        {"id": "claude-old", "section": "overflow", "runtime": {"effort_levels": ["low", "max"]}},
        {"id": "claude-new", "section": "main", "runtime": {"effort_levels": ["low", "xhigh"]}},
        {"id": "claude-light", "section": "overflow",
         "thinking": {"type": "effort", "effort_options": [{"id": "low"}, {"id": "high"}]}},
        {"id": "claude-plain", "section": "overflow", "thinking": {"type": "none"}}
      ]}}}
      """
    let catalog = try #require(AgentModelCatalog.parseClaude(Data(json.utf8)))
    #expect(catalog.primary.map(\.id) == ["claude-new"])
    #expect(catalog.overflow.map(\.id) == ["claude-old", "claude-light", "claude-plain"])
    #expect(catalog.reasoningEfforts(for: "claude-new") == ["low", "xhigh"])
    #expect(catalog.reasoningEfforts(for: "claude-light") == ["low", "high"])
    #expect(catalog.reasoningEfforts(for: "claude-plain") == [])
  }

  @Test func claudeCatalogSpillsALongMainSectionIntoOverflow() throws {
    let main = (1...8).map { #"{"id": "main-\#($0)", "section": "main"}"# }
    let json = #"{"catalog": {"config": {"models": [\#(main.joined(separator: ",")), {"id": "extra"}]}}}"#
    let catalog = try #require(AgentModelCatalog.parseClaude(Data(json.utf8)))
    #expect(catalog.primary.count == AgentModelCatalog.primaryLimit)
    #expect(catalog.overflow.map(\.id) == ["main-7", "main-8", "extra"])
  }

  @Test func claudeCatalogRejectsUnreadableData() {
    #expect(AgentModelCatalog.parseClaude(Data("{}".utf8)) == nil)
    #expect(AgentModelCatalog.parseClaude(Data(#"{"catalog": {"config": {"models": []}}}"#.utf8)) == nil)
  }

  // MARK: - Shared rules

  @Test func catalogDropsDuplicatesAndCapsOverflow() {
    let models = (["a", "a"] + (1...40).map { "m\($0)" }).map { AgentModelCatalog.Model(id: $0) }
    let catalog = AgentModelCatalog(models: models, primaryCount: 1, source: .installedAgent)
    #expect(catalog.primary.map(\.id) == ["a"])
    #expect(catalog.overflow.count == AgentModelCatalog.overflowLimit)
    #expect(catalog.overflow.first?.id == "m1")
    #expect(catalog.allModelIDs.count == 1 + AgentModelCatalog.overflowLimit)
  }

  @Test func reasoningEffortsAreUnknownForModelsOutsideTheCatalog() {
    let catalog = AgentModelCatalog(
      models: [AgentModelCatalog.Model(id: "a", reasoningEfforts: ["low"])],
      primaryCount: 1,
      source: .installedAgent
    )
    #expect(catalog.reasoningEfforts(for: nil) == nil)
    #expect(catalog.reasoningEfforts(for: "custom-model") == nil)
    #expect(catalog.reasoningEfforts(for: "a") == ["low"])
  }

  @Test func builtInCatalogUsesTheAdapterSuggestions() throws {
    let catalog = try #require(AgentModelCatalog.builtIn(for: .codex))
    let adapter = try #require(AgentRuntimeAdapterRegistry.profileAdapter(for: .codex))
    #expect(catalog.source == .builtIn)
    #expect(catalog.allModelIDs == adapter.modelSuggestions)
    #expect(catalog.primary.count == AgentModelCatalog.primaryLimit)
    #expect(AgentModelCatalog.builtIn(for: .gemini) == nil)
  }

  // MARK: - Loader

  @Test func loaderPrefersTheDedicatedHomeCatalog() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let dedicated = root.appending(path: "dedicated", directoryHint: .isDirectory)
    let fallback = root.appending(path: "default", directoryHint: .isDirectory)
    try writeCodexCache(["gpt-dedicated"], in: dedicated)
    try writeCodexCache(["gpt-default"], in: fallback)

    let catalog = AgentModelCatalogLoader.catalog(for: .codex, homes: [dedicated, fallback])
    #expect(catalog?.allModelIDs == ["gpt-dedicated"])
  }

  @Test func loaderFallsBackToTheNextHomeAndThenToBuiltIn() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = root.appending(path: "empty", directoryHint: .isDirectory)
    let fallback = root.appending(path: "default", directoryHint: .isDirectory)
    try writeCodexCache(["gpt-default"], in: fallback)

    #expect(AgentModelCatalogLoader.catalog(for: .codex, homes: [empty, fallback])?.allModelIDs == ["gpt-default"])
    #expect(AgentModelCatalogLoader.catalog(for: .codex, homes: [empty])?.source == .builtIn)
    #expect(AgentModelCatalogLoader.catalog(for: .gemini, homes: [empty]) == nil)
  }

  @Test func loaderReadsTheNewestClaudeCatalogAndIgnoresBadges() throws {
    let home = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = home.appending(path: "cache/model-catalog", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try claudeCatalog(id: "claude-old", fetchedAt: 1).write(to: directory.appending(path: "a-cc.json"))
    try claudeCatalog(id: "claude-new", fetchedAt: 2).write(to: directory.appending(path: "b-cc.json"))
    try claudeCatalog(id: "claude-badge", fetchedAt: 3).write(to: directory.appending(path: "b-cc.badges.json"))

    let catalog = AgentModelCatalogLoader.catalog(for: .claude, homes: [home])
    #expect(catalog?.allModelIDs == ["claude-new"])
    #expect(catalog?.source == .installedAgent)
  }

  @Test func defaultHomesHonorTheRuntimeHomeVariable() {
    let user = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    let dedicated = URL(filePath: "/profiles/1", directoryHint: .isDirectory)
    #expect(
      AgentModelCatalogLoader.homes(for: .codex, dedicatedHome: dedicated, environment: [:], userHome: user)
        .map(\.path) == ["/profiles/1", "/Users/someone/.codex"]
    )
    #expect(
      AgentModelCatalogLoader.homes(
        for: .claude, dedicatedHome: nil, environment: ["CLAUDE_CONFIG_DIR": "/custom/claude"], userHome: user
      )
      .map(\.path) == ["/custom/claude"]
    )
  }

  // MARK: - Helpers

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "AgentModelCatalogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeCodexCache(_ slugs: [String], in home: URL) throws {
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let entries = slugs.enumerated().map { #"{"slug": "\#($1)", "visibility": "list", "priority": \#($0)}"# }
    try Data(#"{"models": [\#(entries.joined(separator: ","))]}"#.utf8)
      .write(to: home.appending(path: "models_cache.json"))
  }

  private func claudeCatalog(id: String, fetchedAt: Int) -> Data {
    Data(
      #"{"fetchedAt": \#(fetchedAt), "catalog": {"config": {"models": [{"id": "\#(id)", "section": "main"}]}}}"#.utf8)
  }
}
