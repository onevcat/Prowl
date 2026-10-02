// ProwlCLI/Skills/SkillsCommandExecutor.swift
// Pure local execution of `prowl skills`: bundle lookup, target selection, link changes.

import Foundation
import ProwlCLIShared

struct SkillsCommandExecutor {
  let skills: [BundledSkill]
  let userRoot: URL
  let currentDirectory: URL

  static let projectScopeNote =
    "Project-scope skill links are absolute paths specific to this Mac. Prowl never edits Git state; "
    + "exclude them yourself (for example in .git/info/exclude) if they should stay out of version control."

  /// Resolves the bundle next to the running executable (or `PROWL_SKILLS_DIR`) and the user root.
  static func current(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
    let skills: [BundledSkill]
    do {
      skills = try ProwlSkills.bundledForCLI(executableURL: currentExecutableURL(), environment: environment)
    } catch let error as ProwlSkillsError {
      throw ExitError(code: error.code.rawValue, message: error.localizedDescription)
    }
    let home: URL
    if let override = environment["HOME"], !override.isEmpty {
      home = URL(filePath: override, directoryHint: .isDirectory)
    } else {
      home = FileManager.default.homeDirectoryForCurrentUser
    }
    return Self(
      skills: skills,
      userRoot: home.standardizedFileURL,
      currentDirectory: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    )
  }

  /// The executable as invoked (possibly a symlink such as `/usr/local/bin/prowl`); the registry
  /// resolves it to the app bundle. `argv[0]` alone may be a bare name and is not used.
  private static func currentExecutableURL() -> URL {
    Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
  }

  // MARK: - Commands

  func list() throws -> SkillsCommandPayload {
    let listed = skills.map { skill in
      SkillsCommandSkill(
        id: skill.id,
        name: skill.name,
        description: skill.description,
        audience: skill.audience,
        path: ProwlSkillInstaller.sourcePath(skill),
        targets: SkillInstallTarget.all.map { target in
          let status = ProwlSkillInstaller.status(skill: skill, target: target, scope: .user, root: userRoot)
          return SkillsCommandTargetStatus(
            id: target.id,
            detected: status.detected,
            path: status.linkPath,
            status: SkillsCommandStatus(status.status),
            destination: status.status.destination
          )
        }
      )
    }
    return .list(SkillsListPayload(skills: listed))
  }

  func install(_ request: SkillsChangeRequest) throws -> SkillsCommandPayload {
    let root = try resolveRoot(request)
    let selectedSkills = try resolveSkills(request.skillIDs, installing: true)
    let targets = try resolveTargets(request.targetIDs, scope: request.scope, root: root, requireDetected: true)
    let pairs = try prepare(skills: selectedSkills, targets: targets, scope: request.scope, root: root)

    let results = try pairs.map { pair in
      // Re-read the slot right before acting: targets whose skills directories alias the same
      // folder (synced ~/.claude/skills and ~/.codex/skills) share one link, so an earlier pair
      // may already have installed it.
      let before = ProwlSkillInstaller.status(skill: pair.skill, target: pair.target, scope: request.scope, root: root)
      var after = before
      if case .installed = before.status {
        // Already linked to this bundle; relinking would only churn the shared slot.
      } else {
        do {
          after = try ProwlSkillInstaller.install(
            skill: pair.skill, target: pair.target, scope: request.scope, root: root)
        } catch {
          throw ExitError(
            code: CLIErrorCode.skillsFailed,
            message: "Failed to link \(pair.skill.id) into \(before.linkPath): \(error.localizedDescription)"
          )
        }
      }
      return SkillsCommandResult(
        skill: pair.skill.id,
        target: pair.target.id,
        path: before.linkPath,
        before: SkillsCommandStatus(before.status),
        after: SkillsCommandStatus(after.status)
      )
    }
    return .install(changePayload(scope: request.scope, root: root, results: results))
  }

  func uninstall(_ request: SkillsChangeRequest) throws -> SkillsCommandPayload {
    let root = try resolveRoot(request)
    let selectedSkills = try resolveSkills(request.skillIDs, installing: false)
    let targets = try resolveTargets(request.targetIDs, scope: request.scope, root: root, requireDetected: false)
    let pairs = try prepare(skills: selectedSkills, targets: targets, scope: request.scope, root: root)

    let results = try pairs.map { pair in
      // Re-read the slot right before acting; an aliased target may already be empty.
      let before = ProwlSkillInstaller.status(skill: pair.skill, target: pair.target, scope: request.scope, root: root)
      var after = before
      if before.status != .notInstalled {
        do {
          after = try ProwlSkillInstaller.uninstall(
            skill: pair.skill, target: pair.target, scope: request.scope, root: root)
        } catch {
          throw ExitError(
            code: CLIErrorCode.skillsFailed,
            message: "Failed to remove \(before.linkPath): \(error.localizedDescription)"
          )
        }
      }
      return SkillsCommandResult(
        skill: pair.skill.id,
        target: pair.target.id,
        path: before.linkPath,
        before: SkillsCommandStatus(before.status),
        after: SkillsCommandStatus(after.status)
      )
    }
    return .uninstall(changePayload(scope: request.scope, root: root, results: results))
  }

  func path(skillID: String) throws -> SkillsCommandPayload {
    let skill = try bundledSkill(id: skillID)
    return .path(
      SkillsPathPayload(
        skill: SkillsCommandSkillReference(
          id: skill.id,
          name: skill.name,
          audience: skill.audience,
          path: ProwlSkillInstaller.sourcePath(skill)
        )
      )
    )
  }

  // MARK: - Selection

  private struct Pair {
    let skill: BundledSkill
    let target: SkillInstallTarget
    let before: SkillTargetStatus
  }

  /// Computes every skill × target slot and refuses the whole operation when any slot is a real
  /// file or directory, so a conflict never leaves a partial result.
  private func prepare(
    skills: [BundledSkill],
    targets: [SkillInstallTarget],
    scope: ProwlSkillScope,
    root: URL
  ) throws -> [Pair] {
    let pairs = skills.flatMap { skill in
      targets.map { target in
        Pair(
          skill: skill,
          target: target,
          before: ProwlSkillInstaller.status(skill: skill, target: target, scope: scope, root: root)
        )
      }
    }
    if scope == .project {
      let escaping = targets.compactMap { ProwlSkillInstaller.projectBoundaryViolation(target: $0, root: root) }
      guard escaping.isEmpty else {
        throw ExitError(
          code: CLIErrorCode.installConflict,
          message: "Refusing to follow a symlinked target directory outside the project: "
            + escaping.joined(separator: ", ")
            + ". Project-scope links stay inside the repository; nothing was changed."
        )
      }
    }
    let conflicts = pairs.filter { SymlinkInstaller.hasConflict(linkPath: $0.before.linkPath) }
    guard conflicts.isEmpty else {
      throw ExitError(
        code: CLIErrorCode.installConflict,
        message: "Refusing to touch a real file or directory (only symlinks are managed): "
          + conflicts.map(\.before.linkPath).joined(separator: ", ")
          + ". Remove it manually or choose other targets; nothing was changed."
      )
    }
    return pairs
  }

  private func resolveSkills(_ ids: [String], installing: Bool) throws -> [BundledSkill] {
    guard !ids.isEmpty else {
      return skills.filter { $0.audience == .user }
    }
    let requested = try ids.map { id in try bundledSkill(id: id) }
    if installing, let workflowSkill = requested.first(where: { $0.audience == .workflow }) {
      throw ExitError(
        code: CLIErrorCode.skillNotInstallable,
        message: "'\(workflowSkill.id)' is a workflow skill: Prowl materializes it for workflow runs and does not "
          + "install it into agent skill folders. Use 'prowl skills path \(workflowSkill.id)' to locate it."
      )
    }
    let requestedIDs = Set(requested.map(\.id))
    return skills.filter { requestedIDs.contains($0.id) }
  }

  private func bundledSkill(id: String) throws -> BundledSkill {
    guard let skill = skills.first(where: { $0.id == id }) else {
      throw ExitError(
        code: CLIErrorCode.skillNotFound,
        message: "No bundled skill named '\(id)'. Run 'prowl skills list' to see the bundled skills."
      )
    }
    return skill
  }

  private func resolveTargets(
    _ ids: [String],
    scope: ProwlSkillScope,
    root: URL,
    requireDetected: Bool
  ) throws -> [SkillInstallTarget] {
    guard !ids.isEmpty else {
      let detected = SkillInstallTarget.all.filter { $0.isDetected(scope: scope, root: root) }
      if requireDetected, detected.isEmpty {
        throw ExitError(
          code: CLIErrorCode.targetNotFound,
          message: "No agent skill directories detected under \(displayPath(root)). "
            + "Pass --target <claude|codex|agents> to create one."
        )
      }
      return detected
    }
    let requested = Set(ids)
    if let unknown = ids.first(where: { SkillInstallTarget.target(id: $0) == nil }) {
      throw ExitError(
        code: CLIErrorCode.targetNotFound,
        message: "Unknown target '\(unknown)'. Supported targets: "
          + SkillInstallTarget.all.map(\.id).joined(separator: ", ") + "."
      )
    }
    return SkillInstallTarget.all.filter { requested.contains($0.id) }
  }

  private func resolveRoot(_ request: SkillsChangeRequest) throws -> URL {
    switch request.scope {
    case .user:
      return userRoot
    case .project:
      let start: URL
      if let projectPath = request.projectPath {
        let url = URL(filePath: projectPath, directoryHint: .isDirectory, relativeTo: currentDirectory)
          .standardizedFileURL
        var isDirectory: ObjCBool = false
        // A trailing slash makes fileExists(atPath:) reject a regular file, hiding PATH_NOT_DIRECTORY.
        guard FileManager.default.fileExists(atPath: displayPath(url), isDirectory: &isDirectory) else {
          throw ExitError(code: CLIErrorCode.pathNotFound, message: "Project path not found: \(displayPath(url))")
        }
        guard isDirectory.boolValue else {
          throw ExitError(
            code: CLIErrorCode.pathNotDirectory, message: "Project path is not a directory: \(displayPath(url))")
        }
        start = url
      } else {
        start = currentDirectory
      }
      // Both spellings name a repository: an explicit path inside a repository resolves to its
      // root, exactly like the current directory does, so links land where runtimes look.
      guard let root = GitRootLocator.root(containing: start) else {
        throw ExitError(
          code: CLIErrorCode.pathNotFound,
          message: "No Git repository contains \(displayPath(start)); project scope needs a repository "
            + "(pass --path <repo> or run inside one)."
        )
      }
      return root
    }
  }

  private func changePayload(scope: ProwlSkillScope, root: URL, results: [SkillsCommandResult]) -> SkillsChangePayload {
    SkillsChangePayload(
      scope: scope,
      root: displayPath(root),
      results: results,
      note: scope == .project ? Self.projectScopeNote : nil
    )
  }

  private func displayPath(_ url: URL) -> String {
    url.path(percentEncoded: false).trimmingTrailingPathSeparator()
  }
}

/// Finds the nearest ancestor (including the start) that contains a `.git` entry. A worktree's
/// `.git` is a file, so both kinds count; no Git process is involved.
enum GitRootLocator {
  static func root(containing directory: URL) -> URL? {
    var current = directory.standardizedFileURL
    while true {
      let marker = current.appending(path: ".git", directoryHint: .notDirectory).path(percentEncoded: false)
      if FileManager.default.fileExists(atPath: marker) {
        return current
      }
      // Stop at the filesystem root: deletingLastPathComponent() of "/" yields "/.." rather than "/".
      let path = current.path(percentEncoded: false).trimmingTrailingPathSeparator()
      guard path != "/", !path.isEmpty else {
        return nil
      }
      current = current.deletingLastPathComponent().standardizedFileURL
    }
  }
}
