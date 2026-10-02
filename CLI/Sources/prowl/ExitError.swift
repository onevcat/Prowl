// ProwlCLI/ExitError.swift
// CLI-specific error that carries an error code for JSON output.

import Foundation

struct ExitError: Error, CustomStringConvertible {
  let code: String
  let message: String

  var description: String { message }
}
