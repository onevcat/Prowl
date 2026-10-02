// ProwlCLI/Commands/DeprecationWarning.swift

import Foundation

func emitDeprecationWarning(command: String, replacement: String) {
  let message = "warning: `prowl \(command)` is deprecated; use `prowl \(replacement)`.\n"
  FileHandle.standardError.write(Data(message.utf8))
}
