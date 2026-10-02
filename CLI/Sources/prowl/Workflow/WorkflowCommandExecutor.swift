// ProwlCLI/Workflow/WorkflowCommandExecutor.swift
// Local execution of `prowl workflow validate` and `prowl workflow schema`: no socket, no app.

import Foundation
import ProwlCLIShared

struct WorkflowCommandExecutor {
  /// nil when the CLI is not inside an app bundle (and `PROWL_SKILLS_DIR` is unset): `skill:`
  /// references are then reported as unchecked warnings instead of failing the file.
  let bundledSkillIDs: Set<String>?
  let homeDirectory: URL
  let currentDirectory: URL

  static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
    let executableURL = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
    let skills = try? ProwlSkills.bundledForCLI(executableURL: executableURL, environment: environment)
    let home: URL
    if let override = environment["HOME"], !override.isEmpty {
      home = URL(filePath: override, directoryHint: .isDirectory)
    } else {
      home = FileManager.default.homeDirectoryForCurrentUser
    }
    return Self(
      bundledSkillIDs: skills.map { Set($0.map(\.id)) },
      homeDirectory: home.standardizedFileURL,
      currentDirectory: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    )
  }

  func validate(path: String, scope explicitScope: WorkflowScope?) throws -> WorkflowValidatePayload {
    let url = URL(filePath: path, directoryHint: .notDirectory, relativeTo: currentDirectory).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
      throw ExitError(code: CLIErrorCode.pathNotFound, message: "No file at \(url.path(percentEncoded: false)).")
    }
    let scope = explicitScope ?? inferredScope(of: url)
    let context = WorkflowValidationContext(scope: scope, bundledSkillIDs: bundledSkillIDs)
    return WorkflowValidatePayload(file: WorkflowDiscovery.load(url: url, scope: scope, context: context))
  }

  func schema(action: Bool = false) throws -> WorkflowSchemaPayload {
    let json = action ? WorkflowActionDefinitionSchema.json : WorkflowJSONSchema.definitionSchemaJSON
    return WorkflowSchemaPayload(schema: RawJSON(Data(json.utf8)))
  }

  /// `~/.prowl/workflows/*` is user scope; any other `.prowl/workflows/*` is repo scope (the
  /// reserved-id rule applies to both); everything else is treated as a user file.
  func inferredScope(of url: URL) -> WorkflowScope {
    let directory = url.deletingLastPathComponent()
    if directory == WorkflowSources.userDirectory(home: homeDirectory).standardizedFileURL {
      return .user
    }
    let components = directory.pathComponents
    if components.count >= 2, components.suffix(2) == [".prowl", "workflows"] {
      return .repo
    }
    return .user
  }
}
