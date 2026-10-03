// ProwlCLI/Commands/ProwlCommand.swift
// Root command with bare path entry detection.

import ArgumentParser
import Foundation
import ProwlCLIShared

struct ProwlCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prowl",
    abstract: "Control a running Prowl instance from the command line.",
    discussion: """
      Prowl bundles agent skills, including prowl-cli, which teaches a coding agent this CLI. \
      Run `prowl skills install` once to link them into your agents' skill folders \
      (~/.claude/skills, ~/.codex/skills, ~/.agents/skills); `prowl skills list` shows the status. \
      The skills commands work locally and do not need the app to be running.
      """,
    version: ProwlVersion.current,
    subcommands: [
      OpenCommand.self,
      ListCommand.self,
      AgentsCommand.self,
      ProfilesCommand.self,
      SkillsCommand.self,
      WorkflowCommand.self,
      FocusCommand.self,
      SendCommand.self,
      KeyCommand.self,
      ReadCommand.self,
      CreateCommand.self,
      CloseCommand.self,
      TabCommand.self,
      PaneCommand.self,
      HandoffCommand.self,
    ],
    defaultSubcommand: OpenCommand.self
  )
}
