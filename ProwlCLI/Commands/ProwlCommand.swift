// ProwlCLI/Commands/ProwlCommand.swift
// Root command with bare path entry detection.

import ArgumentParser
import Foundation
import ProwlCLIShared

struct ProwlCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prowl",
    abstract: "Control a running Prowl instance from the command line.",
    version: ProwlVersion.current,
    subcommands: [
      OpenCommand.self,
      ListCommand.self,
      AgentsCommand.self,
      FocusCommand.self,
      SendCommand.self,
      KeyCommand.self,
      ReadCommand.self,
      TabCommand.self,
      PaneCommand.self,
      BootstrapCommand.self,
    ],
    defaultSubcommand: OpenCommand.self
  )
}
