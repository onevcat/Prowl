// ProwlShared/WorkflowDiscovery.swift
// Three-source workflow discovery (dsl-spec.md §2): bundle < user < repo, `prowl.*` reserved
// for the bundle. Directories that do not exist yield no files.

import Foundation

/// One YAML file found in a workflow source directory, parsed and validated.
nonisolated public struct WorkflowSourceFile: Equatable, Sendable {
  public let scope: WorkflowScope
  public let url: URL
  /// nil when the file did not parse.
  public let definition: WorkflowDefinition?
  /// Parse diagnostics followed by validation diagnostics.
  public let diagnostics: [WorkflowDiagnostic]
  public let snapshot: WorkflowBundleSnapshot?
  public let actions: [String: WorkflowScriptAction]

  public init(
    scope: WorkflowScope, url: URL, definition: WorkflowDefinition?, diagnostics: [WorkflowDiagnostic],
    snapshot: WorkflowBundleSnapshot? = nil, actions: [String: WorkflowScriptAction] = [:]
  ) {
    self.scope = scope
    self.url = url
    self.definition = definition
    self.diagnostics = diagnostics
    self.snapshot = snapshot
    self.actions = actions
  }

  public var id: String? { definition?.id }
  public var isValid: Bool { definition != nil && !diagnostics.hasErrors }
}

/// The directories that hold definitions; nil = the source does not apply (no bundle, no repo).
nonisolated public struct WorkflowSources: Equatable, Sendable {
  public let bundle: URL?
  public let user: URL
  public let repo: URL?

  public init(bundle: URL?, user: URL, repo: URL?) {
    self.bundle = bundle
    self.user = user
    self.repo = repo
  }

  public static let userDirectoryName = "workflows"
  public static let bundleDirectoryName = "workflows"
  public static let repoRelativePath = ".prowl/workflows"

  public static func userDirectory(home: URL) -> URL {
    home.appending(path: ".prowl", directoryHint: .isDirectory)
      .appending(path: userDirectoryName, directoryHint: .isDirectory)
  }

  public static func repoDirectory(root: URL) -> URL {
    root.appending(path: repoRelativePath, directoryHint: .isDirectory)
  }

  public static func bundleDirectory(resourcesURL: URL) -> URL {
    resourcesURL.appending(path: bundleDirectoryName, directoryHint: .isDirectory)
  }
}

nonisolated public struct WorkflowCatalogEntry: Equatable, Sendable {
  public let file: WorkflowSourceFile
  /// A file with the same id in a source of higher precedence wins; this one is not runnable.
  public let shadowed: Bool

  public init(file: WorkflowSourceFile, shadowed: Bool) {
    self.file = file
    self.shadowed = shadowed
  }
}

nonisolated public enum WorkflowDiscovery {
  public static let fileExtensions: Set<String> = ["yaml", "yml"]

  /// Parses and validates every workflow file directly inside `directory`, in file-name order.
  /// A missing directory is an empty source; one that exists but cannot be read throws.
  public static func files(
    in directory: URL?,
    scope: WorkflowScope,
    context: WorkflowValidationContext,
    fileManager: FileManager = .default
  ) throws -> [WorkflowSourceFile] {
    guard let directory, fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
    let contents = try fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    return
      contents
      .filter { $0.pathExtension == "pwlworkflow" || fileExtensions.contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { url in load(url: url, scope: scope, context: context) }
  }

  /// Regular files and symlinks that resolve to one; directories and dangling links are not
  /// definitions even when named `*.yaml`.
  private static func isRegularFile(_ url: URL, _ fileManager: FileManager) -> Bool {
    let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
    let type = (try? fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
    return type == .typeRegular
  }

  /// Parses and validates one file. A file that cannot be read is an `unreadable` error.
  public static func load(url: URL, scope: WorkflowScope, context: WorkflowValidationContext) -> WorkflowSourceFile {
    guard url.pathExtension == "pwlworkflow" else {
      return WorkflowSourceFile(
        scope: scope, url: url, definition: nil,
        diagnostics: [
          .error("unsupported_format", "Use a .pwlworkflow directory containing workflow.yaml (prowl.workflow/v1).")
        ])
    }
    do {
      let snapshot = try WorkflowBundleSnapshot.read(url)
      guard let data = snapshot.files["workflow.yaml"], let yaml = String(data: data, encoding: .utf8) else {
        throw WorkflowExpressionError.type("workflow.yaml must be UTF-8.")
      }
      var actions: [String: WorkflowScriptAction] = [:]
      for path in snapshot.files.keys.sorted() {
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "actions", parts[2] == "action.yaml",
          let data = snapshot.files[path], let source = String(data: data, encoding: .utf8)
        else { continue }
        let id = String(parts[1])
        let action = try WorkflowScriptAction.parse(source, id: id, files: snapshot.files)
        guard snapshot.files["actions/\(id)/\(action.entrypoint)"] != nil else {
          throw WorkflowExpressionError.missing("Entrypoint for local:\(id): \(action.entrypoint)")
        }
        actions[id] = action
      }
      var validationContext = context
      validationContext.localActions = actions
      let parsed = parse(yaml, url: url, scope: scope, context: validationContext)
      return WorkflowSourceFile(
        scope: scope, url: url, definition: parsed.definition,
        diagnostics: parsed.diagnostics, snapshot: snapshot, actions: actions)
    } catch {
      return WorkflowSourceFile(
        scope: scope, url: url, definition: nil,
        diagnostics: [.error("bundle_invalid", "\(error)")])
    }
  }

  public static func parse(
    _ yaml: String, url: URL, scope: WorkflowScope, context: WorkflowValidationContext
  ) -> WorkflowSourceFile {
    let parsed = WorkflowDocumentParser.parse(yaml)
    guard let definition = parsed.definition else {
      return WorkflowSourceFile(scope: scope, url: url, definition: nil, diagnostics: parsed.diagnostics)
    }
    let validation = WorkflowValidator.validate(definition, context: context)
    return WorkflowSourceFile(
      scope: scope, url: url, definition: definition, diagnostics: parsed.diagnostics + validation)
  }

  /// Every file from every source with precedence applied: a valid file shadows valid files with
  /// the same id in lower-precedence sources (repo > user > bundle) and later files in the same
  /// source. Invalid files never shadow and are never shadowed. Order: by id, winners first,
  /// files without an id last.
  public static func catalog(
    sources: WorkflowSources,
    context: (WorkflowScope) -> WorkflowValidationContext,
    fileManager: FileManager = .default
  ) throws -> [WorkflowCatalogEntry] {
    let files =
      try files(in: sources.bundle, scope: .bundle, context: context(.bundle), fileManager: fileManager)
      + files(in: sources.user, scope: .user, context: context(.user), fileManager: fileManager)
      + files(in: sources.repo, scope: .repo, context: context(.repo), fileManager: fileManager)
    var winners: [String: URL] = [:]
    for file in files where file.isValid {
      guard let id = file.id else { continue }
      // Later sources have higher precedence; within a source the first file wins.
      if let existing = winners[id], existingScope(of: existing, in: files) == file.scope {
        continue
      }
      winners[id] = file.url
    }
    return files.map { file in
      let shadowed = file.isValid && file.id.map { winners[$0] != file.url } == true
      return WorkflowCatalogEntry(file: file, shadowed: shadowed)
    }
    .sorted(by: precedes)
  }

  private static func existingScope(of url: URL, in files: [WorkflowSourceFile]) -> WorkflowScope? {
    files.first { $0.url == url }?.scope
  }

  private static func precedes(_ lhs: WorkflowCatalogEntry, _ rhs: WorkflowCatalogEntry) -> Bool {
    switch (lhs.file.id, rhs.file.id) {
    case (nil, nil): return lhs.file.url.path() < rhs.file.url.path()
    case (nil, _): return false
    case (_, nil): return true
    case (let left?, let right?):
      if left != right { return left < right }
      let leftWins = lhs.file.isValid && !lhs.shadowed
      let rightWins = rhs.file.isValid && !rhs.shadowed
      if leftWins != rightWins { return leftWins }
      if lhs.file.scope != rhs.file.scope { return rank(lhs.file.scope) > rank(rhs.file.scope) }
      return lhs.file.url.path() < rhs.file.url.path()
    }
  }

  private static func rank(_ scope: WorkflowScope) -> Int {
    switch scope {
    case .bundle: 0
    case .user: 1
    case .repo: 2
    }
  }
}
