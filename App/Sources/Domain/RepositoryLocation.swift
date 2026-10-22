import Foundation

/// Where a repository or worktree lives. Its encoded form is the repository or
/// worktree ID (docs-ai 084, decision D1); no other code builds or splits an ID.
nonisolated enum RepositoryLocation: Hashable, Sendable {
  /// A directory on this Mac.
  case local(URL)
  /// A directory on the host of a `HostProfile`. The path is canonical on the
  /// host: absolute, without a trailing slash.
  case remote(hostProfileID: UUID, path: String)

  private static let sshPrefix = "ssh:"
  private static let uuidLength = 36

  /// The ID. A local ID is the URL path unchanged, so it stays byte-identical
  /// to the IDs stored before remote folders. A remote ID is
  /// `ssh:<lowercase profile UUID>:<path>`; the fixed UUID length makes the raw
  /// path unambiguous, so it is not escaped.
  var id: String {
    switch self {
    case .local(let url):
      url.path(percentEncoded: false)
    case .remote(let hostProfileID, let path):
      "\(Self.sshPrefix)\(hostProfileID.uuidString.lowercased()):\(path)"
    }
  }

  /// Decodes an ID. Nil when the string is in neither form.
  init?(id: String) {
    if id.hasPrefix("/") {
      self = .local(URL(filePath: id, directoryHint: .inferFromPath))
      return
    }
    guard id.hasPrefix(Self.sshPrefix) else { return nil }
    let rest = id.dropFirst(Self.sshPrefix.count)
    let uuidText = rest.prefix(Self.uuidLength)
    let path = rest.dropFirst(Self.uuidLength + 1)
    guard uuidText.count == Self.uuidLength,
      rest.dropFirst(Self.uuidLength).first == ":",
      Self.isCanonicalRemotePath(path),
      uuidText == uuidText.lowercased(),
      let hostProfileID = UUID(uuidString: String(uuidText))
    else {
      return nil
    }
    self = .remote(hostProfileID: hostProfileID, path: String(path))
  }

  /// The URL of a local location. Nil for a remote one.
  var localURL: URL? {
    guard case .local(let url) = self else { return nil }
    return url
  }

  /// The location with a standardized local URL, so that two spellings of one
  /// local folder name one settings key. A remote path is canonical already.
  var standardized: RepositoryLocation {
    switch self {
    case .local(let url):
      .local(url.standardizedFileURL)
    case .remote:
      self
    }
  }

  /// The path on the location's own host.
  var path: String {
    switch self {
    case .local(let url):
      url.path(percentEncoded: false)
    case .remote(_, let path):
      path
    }
  }

  /// Absolute, and without empty, `.` or `..` components or a trailing slash
  /// (except `/` itself), as `pwd -P` prints it. One remote folder has one ID.
  static func isCanonicalRemotePath(_ path: some StringProtocol) -> Bool {
    guard path.hasPrefix("/") else { return false }
    guard path != "/" else { return true }
    let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    return !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
  }

  /// Whether a stored ID is a local path that path normalization may rewrite.
  /// Remote IDs and strings in neither form are kept as stored, so no home
  /// directory is prepended to them.
  static func isLocalPathForm(_ storedID: String) -> Bool {
    let trimmed = storedID.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
  }

  /// Whether a stored ID or repository root has the remote form.
  static func hasRemoteForm(_ stored: String) -> Bool {
    stored.hasPrefix(sshPrefix)
  }
}
