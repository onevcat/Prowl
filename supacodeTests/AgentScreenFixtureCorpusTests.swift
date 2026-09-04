import Foundation
import Testing

@testable import supacode

struct AgentScreenFixtureCorpusTests {
  @Test func initialCorpusCoversClaudeAndCodexLifecycleStates() throws {
    let fixtures = try AgentScreenFixtureCorpus.load()

    for agent in [DetectedAgent.claude, .codex] {
      let states =
        fixtures
        .filter { $0.agent == agent && !$0.isQuarantined }
        .map(\.expectedState)
      #expect(states.contains(.blocked))
      #expect(states.contains(.working))
      #expect(states.contains(.idle))
    }
  }

  @Test func corpusContainsCapturedLiveFooterRegressions() throws {
    let paths = Set(try AgentScreenFixtureCorpus.load().map(\.relativePath))

    #expect(paths.contains("pi/0.85.0/working/framed-footer.txt"))
    #expect(paths.contains("codex/0.153.2/working/background-terminal-footer.txt"))
  }

  @Test func corpusRejectsUnexpectedRegularFiles() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    try Data().write(to: temporaryRoot.appending(path: "README.md"))
    try Data().write(to: temporaryRoot.appending(path: "raw-capture.json"))

    #expect(throws: CorpusError.self) {
      try AgentScreenFixtureCorpus.load(from: temporaryRoot)
    }
  }

  @Test func corpusRequiresExplicitIssueMetadataKey() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fixtureDirectory = temporaryRoot.appending(path: "claude/1.0/idle", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    try "idle".write(to: fixtureDirectory.appending(path: "composer.txt"), atomically: true, encoding: .utf8)
    try """
    {
      "schema_version": 1,
      "captured_at": "2026-08-07T00:00:00Z",
      "cli_version": "1.0",
      "capture_source": "prowl-read-detection",
      "terminal": { "columns": 80, "rows": 24 },
      "redactions": ["none required"]
    }
    """.write(
      to: fixtureDirectory.appending(path: "composer.metadata.json"),
      atomically: true,
      encoding: .utf8
    )

    do {
      _ = try AgentScreenFixtureCorpus.load(from: temporaryRoot)
    } catch is DecodingError {
      return
    }
    Issue.record("Fixture metadata without an explicit issue key was accepted.")
  }

  @Test func capturedFixturesMatchCurrentDetector() throws {
    let fixtures = try AgentScreenFixtureCorpus.load()

    #expect(!fixtures.isEmpty, "The captured screen corpus must not be empty.")
    for fixture in fixtures {
      // The corpus must hold exact production detector inputs. For agents
      // that consume the bounded tail this is checkable directly; for Claude
      // the tail check is x == x, so the enforceable invariant is that a
      // full-active-screen capture cannot exceed the captured viewport.
      if fixture.agent == .claude {
        let lineCount = fixture.text
          .split(separator: "\n", omittingEmptySubsequences: false)
          .count
        #expect(
          lineCount <= fixture.metadata.terminal.rows,
          "Claude fixtures are full screens and cannot exceed the captured terminal rows: \(fixture.relativePath)"
        )
      } else {
        #expect(
          fixture.text == fixture.agent.detectionScreenText(from: fixture.text),
          "Fixture is not the exact detector input for its agent: \(fixture.relativePath)"
        )
      }

      let actualState = fixture.agent.detectState(in: fixture.text)
      let mismatchMessage =
        "Fixture \(fixture.relativePath) expected \(fixture.currentState.rawValue), got \(actualState.rawValue)"
      #expect(actualState == fixture.currentState, Comment(rawValue: mismatchMessage))

      if fixture.isQuarantined {
        #expect(
          fixture.expectedState != fixture.currentState,
          "Quarantined fixture no longer describes a misdetection: \(fixture.relativePath)"
        )
        #expect(
          fixture.metadata.issue != nil,
          "Quarantined fixture must link an issue: \(fixture.relativePath)"
        )
      } else {
        #expect(fixture.expectedState == fixture.currentState)
        #expect(fixture.metadata.issue == nil)
      }
    }
  }
}

enum AgentScreenFixtureCorpus {
  static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/AgentScreenDetection", directoryHint: .isDirectory)

  static func load(from fixtureRoot: URL = root) throws -> [AgentScreenFixture] {
    let fixtureRoot = fixtureRoot.standardizedFileURL.resolvingSymlinksInPath()
    let fileManager = FileManager.default
    guard
      let enumerator = fileManager.enumerator(
        at: fixtureRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      throw CorpusError("Fixture root is unavailable: \(fixtureRoot.path(percentEncoded: false))")
    }

    let urls = enumerator.compactMap { ($0 as? URL)?.standardizedFileURL.resolvingSymlinksInPath() }
    let regularFileURLs = try urls.filter {
      try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    }
    let readmeURL = fixtureRoot.appending(path: "README.md")
    let unexpectedURLs = regularFileURLs.filter { url in
      url != readmeURL
        && url.pathExtension != "txt"
        && !url.lastPathComponent.hasSuffix(".metadata.json")
    }
    guard unexpectedURLs.isEmpty else {
      let unexpectedPaths = unexpectedURLs.map { relativePath(for: $0, root: fixtureRoot) }.sorted()
      throw CorpusError("Unexpected files in fixture corpus: \(unexpectedPaths)")
    }

    let screenURLs =
      regularFileURLs
      .filter { $0.pathExtension == "txt" }
      .sorted { $0.path() < $1.path() }
    let metadataURLs = Set(regularFileURLs.filter { $0.lastPathComponent.hasSuffix(".metadata.json") })

    var consumedMetadataURLs: Set<URL> = []
    let fixtures = try screenURLs.map { screenURL in
      let fixture = try loadFixture(at: screenURL, root: fixtureRoot)
      consumedMetadataURLs.insert(fixture.metadataURL)
      return fixture
    }

    let orphanedMetadata = metadataURLs.subtracting(consumedMetadataURLs)
    guard orphanedMetadata.isEmpty else {
      throw CorpusError(
        "Metadata without a matching screen fixture: \(orphanedMetadata.map(\.lastPathComponent).sorted())"
      )
    }
    return fixtures
  }

  private static func loadFixture(at screenURL: URL, root: URL) throws -> AgentScreenFixture {
    let relativePath = relativePath(for: screenURL, root: root)
    let components = relativePath.split(separator: "/").map(String.init)
    let layout = try FixtureLayout(components: components, relativePath: relativePath)
    let metadataURL = screenURL.deletingPathExtension().appendingPathExtension("metadata.json")

    guard FileManager.default.fileExists(atPath: metadataURL.path(percentEncoded: false)) else {
      throw CorpusError("Missing metadata for \(relativePath)")
    }

    let metadata = try JSONDecoder().decode(
      AgentScreenFixtureMetadata.self,
      from: Data(contentsOf: metadataURL)
    )
    try validate(metadata: metadata, layout: layout, relativePath: relativePath)

    return AgentScreenFixture(
      relativePath: relativePath,
      metadataURL: metadataURL,
      agent: layout.agent,
      expectedState: layout.expectedState,
      currentState: layout.currentState,
      isQuarantined: layout.isQuarantined,
      text: try String(contentsOf: screenURL, encoding: .utf8),
      metadata: metadata
    )
  }

  private static func validate(
    metadata: AgentScreenFixtureMetadata,
    layout: FixtureLayout,
    relativePath: String
  ) throws {
    guard metadata.schemaVersion == 1 else {
      throw CorpusError("Unsupported metadata schema for \(relativePath): \(metadata.schemaVersion)")
    }
    guard metadata.cliVersion == layout.cliVersion else {
      throw CorpusError("CLI version metadata does not match path for \(relativePath)")
    }
    guard metadata.captureSource == "prowl-read-detection" else {
      throw CorpusError("Invalid capture source for \(relativePath): \(metadata.captureSource)")
    }
    guard ISO8601DateFormatter().date(from: metadata.capturedAt) != nil else {
      throw CorpusError("Invalid capture timestamp for \(relativePath): \(metadata.capturedAt)")
    }
    guard metadata.terminal.columns > 0, metadata.terminal.rows > 0 else {
      throw CorpusError("Invalid terminal geometry for \(relativePath)")
    }
    guard !metadata.redactions.isEmpty else {
      throw CorpusError("Missing redaction summary for \(relativePath)")
    }
  }

  private static func relativePath(for url: URL, root: URL) -> String {
    let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    let urlPath = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    let path = String(urlPath.dropFirst(rootPath.count))
    return path.hasPrefix("/") ? String(path.dropFirst()) : path
  }
}

struct AgentScreenFixture {
  let relativePath: String
  let metadataURL: URL
  let agent: DetectedAgent
  let expectedState: AgentRawState
  let currentState: AgentRawState
  let isQuarantined: Bool
  let text: String
  let metadata: AgentScreenFixtureMetadata
}

struct AgentScreenFixtureMetadata: Decodable {
  struct Terminal: Decodable {
    let columns: Int
    let rows: Int
  }

  let schemaVersion: Int
  let capturedAt: String
  let cliVersion: String
  let captureSource: String
  let terminal: Terminal
  let redactions: [String]
  let issue: String?

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case capturedAt = "captured_at"
    case cliVersion = "cli_version"
    case captureSource = "capture_source"
    case terminal
    case redactions
    case issue
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.contains(.issue) else {
      throw DecodingError.keyNotFound(
        CodingKeys.issue,
        DecodingError.Context(
          codingPath: container.codingPath,
          debugDescription: "Fixture metadata must include issue as a URL or explicit null."
        )
      )
    }
    self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    self.capturedAt = try container.decode(String.self, forKey: .capturedAt)
    self.cliVersion = try container.decode(String.self, forKey: .cliVersion)
    self.captureSource = try container.decode(String.self, forKey: .captureSource)
    self.terminal = try container.decode(Terminal.self, forKey: .terminal)
    self.redactions = try container.decode([String].self, forKey: .redactions)
    self.issue = try container.decodeIfPresent(String.self, forKey: .issue)
  }
}

private struct FixtureLayout {
  let agent: DetectedAgent
  let cliVersion: String
  let expectedState: AgentRawState
  let currentState: AgentRawState
  let isQuarantined: Bool

  init(components: [String], relativePath: String) throws {
    guard components.count == 4 || components.count == 6 else {
      throw CorpusError("Invalid fixture path layout: \(relativePath)")
    }
    guard let agent = DetectedAgent(rawValue: components[0]) else {
      throw CorpusError("Unknown runtime in fixture path: \(relativePath)")
    }
    self.agent = agent
    self.cliVersion = components[1]

    if components.count == 4 {
      guard let state = AgentRawState(rawValue: components[2]) else {
        throw CorpusError("Invalid expected state in fixture path: \(relativePath)")
      }
      self.expectedState = state
      self.currentState = state
      self.isQuarantined = false
    } else {
      guard components[2] == "known-misdetection",
        let expectedState = AgentRawState(rawValue: components[3]),
        let currentState = AgentRawState(rawValue: components[4])
      else {
        throw CorpusError("Invalid quarantine path layout: \(relativePath)")
      }
      self.expectedState = expectedState
      self.currentState = currentState
      self.isQuarantined = true
    }
  }
}

struct CorpusError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
