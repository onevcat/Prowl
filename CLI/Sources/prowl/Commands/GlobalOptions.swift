// ProwlCLI/Commands/GlobalOptions.swift
// Shared output options.

import ArgumentParser
import ProwlCLIShared

struct GlobalOptions: ParsableArguments {
  @Flag(name: .long, help: "Output in JSON format matching schema contracts.")
  var json = false

  @Flag(name: .long, help: "Disable colored output.")
  var noColor = false

  var outputMode: OutputMode {
    json ? .json : .text
  }

  var colorEnabled: Bool {
    !noColor && !json
  }
}
