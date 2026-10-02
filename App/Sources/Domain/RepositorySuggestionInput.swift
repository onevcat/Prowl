import Foundation

/// Builds the bounded natural-language input for an SF Symbol
/// suggestion run. Sources are tried in a fixed order — cleaned README
/// synopsis, root manifest description, repository display name — and
/// the winner is reported so the UI can disclose it. The synopsis is
/// visible text, not a raw prefix: front matter, badges, fenced code,
/// and markup are dropped before the character cap, which keeps the
/// budget meaningful for CJK prose as well.
nonisolated struct RepositorySuggestionInput: Equatable, Sendable {
  /// Matches GlyphonKit's internal prompt budget.
  static let maxLength = 600
  /// A README whose visible text is shorter than this is treated as
  /// empty (badge-only READMEs are common) and falls through.
  static let minimumUsefulLength = 24
  private static let maxSourceBytes = 256 * 1024

  let text: String
  let source: RepositorySymbolSuggestions.Source

  static func build(
    rootURL: URL,
    repositoryDisplayName: String,
    fileManager: FileManager = .default
  ) -> RepositorySuggestionInput {
    if let synopsis = readmeSynopsis(rootURL: rootURL, fileManager: fileManager) {
      return RepositorySuggestionInput(text: synopsis, source: .readme)
    }
    if let description = manifestDescription(rootURL: rootURL) {
      return RepositorySuggestionInput(text: description, source: .manifestDescription)
    }
    return RepositorySuggestionInput(
      text: String(repositoryDisplayName.prefix(maxLength)),
      source: .repositoryName
    )
  }

  // MARK: - README

  private static func readmeSynopsis(rootURL: URL, fileManager: FileManager) -> String? {
    guard let entries = try? fileManager.contentsOfDirectory(atPath: rootURL.path(percentEncoded: false))
    else {
      return nil
    }
    let preferredNames = ["readme.md", "readme.markdown", "readme.mdown", "readme.txt", "readme"]
    let readme = preferredNames.lazy
      .compactMap { preferred in entries.first { $0.lowercased() == preferred } }
      .first
    guard let readme,
      let raw = boundedText(at: rootURL.appending(path: readme, directoryHint: .notDirectory))
    else {
      return nil
    }
    let cleaned = cleanedMarkdownSynopsis(raw)
    guard cleaned.count >= minimumUsefulLength else { return nil }
    return cleaned
  }

  /// Reduces markdown to the prose a reader actually sees, capped to
  /// `maxLength` characters.
  static func cleanedMarkdownSynopsis(_ markdown: String) -> String {
    var text = markdown
    // YAML front matter at the very top.
    text = text.replacing(/\A---\n[\s\S]*?\n---\n/, with: "")
    // Fenced code blocks, HTML comments, then remaining inline HTML.
    text = text.replacing(/(?:```|~~~)[\s\S]*?(?:```|~~~)/, with: " ")
    text = text.replacing(/<!--[\s\S]*?-->/, with: " ")
    text = text.replacing(/<[^>\n]+>/, with: " ")
    // Images (badges) vanish entirely; links keep their visible text.
    text = text.replacing(/!\[[^\]]*\]\([^)]*\)/, with: " ")
    text = text.replacing(/\[([^\]]*)\]\([^)]*\)/) { match in String(match.output.1) }
    // Reference-style link definitions occupy whole lines.
    text = text.replacing(/^\s*\[[^\]]+\]:\s+\S+.*$/.anchorsMatchLineEndings(), with: " ")
    // Markup characters that survive the structural passes.
    text = text.replacing(/[#>*_`|]+/, with: " ")
    text = text.replacing(/\s+/, with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(text.prefix(maxLength))
  }

  // MARK: - Manifest descriptions

  private static func manifestDescription(rootURL: URL) -> String? {
    if let description = packageJSONDescription(rootURL: rootURL) {
      return description
    }
    if let description = pubspecDescription(rootURL: rootURL) {
      return description
    }
    if let description = cargoDescription(rootURL: rootURL) {
      return description
    }
    return nil
  }

  private static func packageJSONDescription(rootURL: URL) -> String? {
    struct Manifest: Decodable {
      let description: String?
    }
    let url = rootURL.appending(path: "package.json", directoryHint: .notDirectory)
    guard let data = boundedData(at: url),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
    else {
      return nil
    }
    return normalizedDescription(manifest.description)
  }

  private static func pubspecDescription(rootURL: URL) -> String? {
    let url = rootURL.appending(path: "pubspec.yaml", directoryHint: .notDirectory)
    guard let text = boundedText(at: url),
      let match = text.firstMatch(of: /^description:\s*(?:>-?\s*)?["']?([^"'\n]+)["']?\s*$/.anchorsMatchLineEndings())
    else {
      return nil
    }
    return normalizedDescription(String(match.output.1))
  }

  private static func cargoDescription(rootURL: URL) -> String? {
    let url = rootURL.appending(path: "Cargo.toml", directoryHint: .notDirectory)
    guard let text = boundedText(at: url),
      let match = text.firstMatch(of: /^description\s*=\s*"([^"\n]+)"/.anchorsMatchLineEndings())
    else {
      return nil
    }
    return normalizedDescription(String(match.output.1))
  }

  private static func normalizedDescription(_ description: String?) -> String? {
    guard let description else { return nil }
    let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(maxLength))
  }

  // MARK: - Bounded IO

  private static func boundedData(at url: URL) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    return try? handle.read(upToCount: maxSourceBytes)
  }

  private static func boundedText(at url: URL) -> String? {
    guard let data = boundedData(at: url) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
