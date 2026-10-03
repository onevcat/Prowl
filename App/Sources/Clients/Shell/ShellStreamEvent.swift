nonisolated enum ShellStreamSource: Equatable, Sendable {
  case stdout
  case stderr
}

nonisolated struct ShellStreamLine: Equatable, Sendable {
  let source: ShellStreamSource
  let text: String
}

nonisolated enum ShellStreamEvent: Equatable, Sendable {
  case line(ShellStreamLine)
  case finished(ShellOutput)
}
