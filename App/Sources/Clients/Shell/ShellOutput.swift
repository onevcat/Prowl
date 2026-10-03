nonisolated struct ShellOutput: Equatable, Sendable {
  let stdout: String
  let stderr: String
  let exitCode: Int32
}
