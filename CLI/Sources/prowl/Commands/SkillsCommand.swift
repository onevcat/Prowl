// ProwlCLI/Commands/SkillsCommand.swift
// Local-only management of Prowl's bundled agent skills. Never opens the socket.

import ArgumentParser
import Foundation
import ProwlCLIShared

struct SkillsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "skills",
    abstract: "Link Prowl's bundled agent skills into agent skill folders.",
    discussion: """
      Runs locally against the skills bundled with this Prowl app; it never contacts or launches \
      the app. Targets: claude (~/.claude/skills), codex (~/.codex/skills), agents (~/.agents/skills).
      """,
    subcommands: [
      SkillsListCommand.self,
      SkillsInstallCommand.self,
      SkillsUninstallCommand.self,
      SkillsPathCommand.self,
    ]
  )
}

struct SkillsChangeRequest: Equatable {
  var skillIDs: [String] = []
  var targetIDs: [String] = []
  var scope: ProwlSkillScope = .user
  var projectPath: String?
}

struct SkillsChangeOptions: ParsableArguments {
  enum Scope: String, ExpressibleByArgument {
    case user
    case project

    var value: ProwlSkillScope {
      switch self {
      case .user: .user
      case .project: .project
      }
    }
  }

  @Argument(help: "Bundled skill ids. Defaults to every user-installable bundled skill.")
  var skills: [String] = []

  @Option(
    name: .long,
    parsing: .singleValue,
    help: "Target id (repeatable): claude, codex, or agents. Defaults to every detected target."
  )
  var target: [String] = []

  @Option(name: .long, help: "Scope: user (default) or project.")
  var scope: Scope = .user

  @Option(name: .long, help: "Project root for --scope project. Defaults to the Git root of the current directory.")
  var path: String?

  func makeRequest() throws -> SkillsChangeRequest {
    if path != nil, scope != .project {
      throw ExitError(code: CLIErrorCode.invalidArgument, message: "--path requires --scope project.")
    }
    return SkillsChangeRequest(skillIDs: skills, targetIDs: target, scope: scope.value, projectPath: path)
  }
}

struct SkillsListCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List bundled skills with their install status per target."
  )

  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try SkillsCommandRunner.run(options: options) { executor in
      try executor.list()
    }
  }
}

struct SkillsInstallCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "install",
    abstract: "Link bundled skills into agent skill folders."
  )

  @OptionGroup var change: SkillsChangeOptions
  @OptionGroup var options: GlobalOptions

  func makeRequest() throws -> SkillsChangeRequest {
    try change.makeRequest()
  }

  mutating func run() throws {
    try SkillsCommandRunner.run(options: options) { executor in
      try executor.install(try makeRequest())
    }
  }
}

struct SkillsUninstallCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "uninstall",
    abstract: "Remove bundled skill links from agent skill folders."
  )

  @OptionGroup var change: SkillsChangeOptions
  @OptionGroup var options: GlobalOptions

  func makeRequest() throws -> SkillsChangeRequest {
    try change.makeRequest()
  }

  mutating func run() throws {
    try SkillsCommandRunner.run(options: options) { executor in
      try executor.uninstall(try makeRequest())
    }
  }
}

struct SkillsPathCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "path",
    abstract: "Print the bundled directory of a skill (any audience)."
  )

  @Argument(help: "Bundled skill id.")
  var skill: String

  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try SkillsCommandRunner.run(options: options) { executor in
      try executor.path(skillID: skill)
    }
  }
}

enum SkillsCommandRunner {
  static let commandName = "skills"

  static func run(
    options: GlobalOptions,
    _ body: (SkillsCommandExecutor) throws -> SkillsCommandPayload
  ) throws {
    try CLIExecution.run(command: commandName, output: options.outputMode, colorEnabled: options.colorEnabled) {
      let executor = try SkillsCommandExecutor.current()
      let payload = try body(executor)
      let response = CommandResponse(
        ok: true,
        command: commandName,
        schemaVersion: SkillsCommandPayload.schemaVersion,
        data: try RawJSON(encoding: payload)
      )
      OutputRenderer.render(response, mode: options.outputMode)
    }
  }
}
