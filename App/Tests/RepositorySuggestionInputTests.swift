import Foundation
import Testing

@testable import supacode

struct RepositorySuggestionInputTests {
  // MARK: - Markdown cleaning

  @Test func stripsFrontMatterBadgesCodeAndMarkup() {
    let markdown = """
      ---
      title: Demo
      ---
      # Kingfisher

      ![badge](https://img.shields.io/build.svg) ![badge2](https://example.com/b2.svg)

      A lightweight, pure-Swift library for downloading and caching images from the web.

      ```swift
      let code = "should disappear"
      ```

      See the [documentation](https://example.com/docs) for details.
      """
    let cleaned = RepositorySuggestionInput.cleanedMarkdownSynopsis(markdown)
    #expect(!cleaned.contains("title: Demo"))
    #expect(!cleaned.contains("shields.io"))
    #expect(!cleaned.contains("should disappear"))
    #expect(!cleaned.contains("#"))
    #expect(!cleaned.contains("https://example.com/docs"))
    #expect(cleaned.contains("Kingfisher"))
    #expect(cleaned.contains("pure-Swift library for downloading and caching images"))
    #expect(cleaned.contains("documentation"))
  }

  @Test func capsAtSixHundredCharacters() {
    let long = String(repeating: "词", count: 2000)
    let cleaned = RepositorySuggestionInput.cleanedMarkdownSynopsis(long)
    #expect(cleaned.count == RepositorySuggestionInput.maxLength)
  }

  @Test func stripsHTMLTagsAndComments() {
    let markdown = """
      <p align="center"><img src="logo.png" width="400"></p>
      <!-- hidden note -->
      A terminal orchestrator for coding agents.
      """
    let cleaned = RepositorySuggestionInput.cleanedMarkdownSynopsis(markdown)
    #expect(!cleaned.contains("<p"))
    #expect(!cleaned.contains("hidden note"))
    #expect(cleaned.contains("A terminal orchestrator for coding agents."))
  }

  // MARK: - Source order

  @Test func readmeWinsOverManifestDescription() throws {
    try withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "README.md": Data(
          "A sufficiently long readme body describing the project purpose in prose.".utf8
        ),
        "package.json": Data(#"{"description":"manifest description"}"#.utf8),
      ]
    ) { root in
      let input = RepositorySuggestionInput.build(rootURL: root, repositoryDisplayName: "demo")
      #expect(input.source == .readme)
      #expect(input.text.contains("readme body"))
    }
  }

  @Test func badgeOnlyReadmeFallsThroughToManifest() throws {
    try withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "README.md": Data("![b](https://x/b.svg) ![c](https://x/c.svg)".utf8),
        "package.json": Data(#"{"description":"A static site generator for personal blogs."}"#.utf8),
      ]
    ) { root in
      let input = RepositorySuggestionInput.build(rootURL: root, repositoryDisplayName: "demo")
      #expect(input.source == .manifestDescription)
      #expect(input.text == "A static site generator for personal blogs.")
    }
  }

  @Test func pubspecDescriptionIsExtracted() throws {
    try withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "pubspec.yaml": Data(
          "name: demo\ndescription: A dog care scheduling app.\nversion: 1.0.0\n".utf8
        )
      ]
    ) { root in
      let input = RepositorySuggestionInput.build(rootURL: root, repositoryDisplayName: "demo")
      #expect(input.source == .manifestDescription)
      #expect(input.text == "A dog care scheduling app.")
    }
  }

  @Test func cargoDescriptionIsExtracted() throws {
    try withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "Cargo.toml": Data(
          "[package]\nname = \"demo\"\ndescription = \"An HTTP client for testing APIs.\"\n".utf8
        )
      ]
    ) { root in
      let input = RepositorySuggestionInput.build(rootURL: root, repositoryDisplayName: "demo")
      #expect(input.source == .manifestDescription)
      #expect(input.text == "An HTTP client for testing APIs.")
    }
  }

  @Test func fallsBackToRepositoryDisplayName() throws {
    try withTemporaryProjectDirectory(entries: ["src/"]) { root in
      let input = RepositorySuggestionInput.build(rootURL: root, repositoryDisplayName: "Prowl")
      #expect(input.source == .repositoryName)
      #expect(input.text == "Prowl")
    }
  }

  @Test func caseInsensitiveReadmeLookup() throws {
    try withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "ReadMe.MD": Data(
          "This readme uses a nonstandard filename case but is long enough to qualify.".utf8
        )
      ]
    ) { root in
      let input = RepositorySuggestionInput.build(rootURL: root, repositoryDisplayName: "demo")
      #expect(input.source == .readme)
    }
  }
}
