import Foundation

nonisolated public struct WorkflowBundleIntegrityError: Error, Equatable, Sendable {
  public let message =
    "Approved definition was modified or is unreadable. Cancel this run and start a newly reviewed run."
}

nonisolated public struct WorkflowPreparedBundle: Equatable, Sendable {
  public let directory: URL
  public let fingerprint: String
  public let actions: [String: WorkflowScriptAction]
  public let interpreters: [String: String]

  public init(source: WorkflowSourceFile, directory: URL, environment: [String: String]) throws {
    guard let snapshot = source.snapshot else { throw WorkflowExpressionError.missing("Bundle snapshot") }
    self.directory = directory
    fingerprint = snapshot.fingerprint
    actions = source.actions
    var resolved: [String: String] = [:]
    for (id, action) in actions {
      resolved[id] = try Self.resolveInterpreter(action.interpreter, environment: environment)
    }
    interpreters = resolved
    try snapshot.copy(to: directory)
  }

  public func verifyIntegrity() throws {
    guard let snapshot = try? WorkflowBundleSnapshot.read(directory), snapshot.fingerprint == fingerprint else {
      throw WorkflowBundleIntegrityError()
    }
  }

  public static func resolveInterpreter(_ executable: String, environment: [String: String]) throws -> String {
    let candidates: [String]
    if executable.hasPrefix("/") {
      candidates = [executable]
    } else {
      guard !executable.contains("/") else {
        throw WorkflowExpressionError.type("Interpreter must be a name or absolute path.")
      }
      candidates = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":")
        .filter { $0.hasPrefix("/") }.map { String($0) + "/" + executable }
    }
    guard
      let found = candidates.first(where: { path in
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
          && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
      })
    else {
      throw WorkflowExpressionError.missing("Interpreter '\(executable)' is not installed or not on PATH.")
    }
    return URL(filePath: found).resolvingSymlinksInPath().path
  }

  public static func environment(for action: WorkflowScriptAction, inherited: [String: String]) -> [String: String] {
    let names = Set(["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"] + action.inheritedEnvironmentNames)
    var result = inherited.filter { names.contains($0.key) && !$0.key.hasPrefix("PROWL_") }
    // Python helper imports must not add bytecode to the integrity-checked definition.
    result["PYTHONDONTWRITEBYTECODE"] = "1"
    return result
  }
}
