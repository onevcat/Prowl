import AppKit
import ComposableArchitecture
import Foundation
import ProwlCLIShared

struct SkillInstallError: Error, Equatable, Sendable, LocalizedError {
  let message: String

  var errorDescription: String? { message }
}

/// User-scope skill links for the Settings Agent Skills section (docs-ai 065): the same shared
/// installer `prowl skills` uses, so both surfaces report identical statuses. Real files and
/// directories are never replaced or deleted; only symlinks are managed.
struct SkillInstallClient: Sendable {
  /// Every bundled skill in bundle order, any audience; callers filter by `audience`.
  var bundledSkills: @Sendable () throws -> [BundledSkill]
  var status: @Sendable (_ skill: BundledSkill, _ target: SkillInstallTarget) -> SkillTargetStatus
  /// Links the bundled skill into the target's user skills directory, replacing a live or dangling
  /// symlink; this doubles as Repair and Replace.
  var install: @Sendable (_ skill: BundledSkill, _ target: SkillInstallTarget) async throws -> Void
  var uninstall: @Sendable (_ skill: BundledSkill, _ target: SkillInstallTarget) async throws -> Void
  var revealSkill: @Sendable (_ skill: BundledSkill) -> Void
}

extension SkillInstallClient: DependencyKey {
  static let liveValue = SkillInstallClient.live(
    resourcesURL: Bundle.main.resourceURL,
    userRoot: FileManager.default.homeDirectoryForCurrentUser
  )

  static let testValue = SkillInstallClient(
    bundledSkills: { [] },
    status: { _, target in SkillTargetStatus(target: target, detected: false, linkPath: "", status: .notInstalled) },
    install: { _, _ in },
    uninstall: { _, _ in },
    revealSkill: { _ in }
  )

  /// The live client over an explicit bundle and home, so tests run against temporary roots.
  static func live(resourcesURL: URL?, userRoot: URL) -> SkillInstallClient {
    SkillInstallClient(
      bundledSkills: {
        guard let resourcesURL else {
          throw SkillInstallError(message: "Could not locate the app's bundled resources.")
        }
        do {
          return try ProwlSkills.bundled(resourcesURL: resourcesURL)
        } catch {
          throw SkillInstallError(message: error.localizedDescription)
        }
      },
      status: { skill, target in
        ProwlSkillInstaller.status(skill: skill, target: target, scope: .user, root: userRoot)
      },
      install: { skill, target in
        do {
          _ = try ProwlSkillInstaller.install(skill: skill, target: target, scope: .user, root: userRoot)
        } catch let error as SymlinkInstallError {
          throw SkillInstallError(message: skillInstallErrorMessage(error))
        } catch {
          throw SkillInstallError(message: error.localizedDescription)
        }
      },
      uninstall: { skill, target in
        do {
          _ = try ProwlSkillInstaller.uninstall(skill: skill, target: target, scope: .user, root: userRoot)
        } catch let error as SymlinkInstallError {
          throw SkillInstallError(message: skillInstallErrorMessage(error))
        } catch {
          throw SkillInstallError(message: error.localizedDescription)
        }
      },
      revealSkill: { skill in
        NSWorkspace.shared.activateFileViewerSelecting([skill.directoryURL])
      }
    )
  }
}

private nonisolated func skillInstallErrorMessage(_ error: SymlinkInstallError) -> String {
  switch error {
  case .conflict(let path):
    "A real file or directory occupies \(path). "
      + "Prowl only manages symlinks and never deletes it; remove it manually first."
  case .notInstalled(let path):
    "No skill link found at \(path)."
  case .sourceNotFound(let path):
    "Bundled skill not found at \(path)."
  }
}

extension DependencyValues {
  var skillInstallClient: SkillInstallClient {
    get { self[SkillInstallClient.self] }
    set { self[SkillInstallClient.self] = newValue }
  }
}
