import Darwin
import Foundation

/// Private app subprocess: the PTY belongs to a display replica, never a remote program.
nonisolated enum MirrorRelay {
  static let argument = "--prowl-internal-mirror-relay"

  static func runIfRequested() {
    let args = CommandLine.arguments
    guard args.count > 1, args[1] == argument else { return }
    guard args.count == 4, let port = UInt16(args[2]), port > 0 else { exit(2) }
    do {
      try run(port: port, token: args[3])
      exit(0)
    } catch { exit(1) }
  }

  private static func run(port: UInt16, token: String) throws {
    signal(SIGPIPE, SIG_IGN)
    var settings = termios()
    guard tcgetattr(STDIN_FILENO, &settings) == 0 else { throw MirrorProtocolError.invalidMessage }
    cfmakeraw(&settings)
    guard tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0 else { throw MirrorProtocolError.invalidMessage }
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw MirrorProtocolError.invalidMessage }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else { throw MirrorProtocolError.invalidMessage }
    try writeAll(try MirrorWire.encode(MirrorMessage(kind: .list, bytes: Data(token.utf8))), to: descriptor)
    var polls = [
      pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
      pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
    ]
    while true {
      let count = polls.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, 2, -1) }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw MirrorProtocolError.invalidMessage }
      if polls[0].revents & Int16(POLLIN) != 0 {
        let length = try MirrorWire.length(readExactly(4, from: descriptor))
        let message = try MirrorWire.decode(readExactly(length, from: descriptor))
        if message.kind == .ping {
          try writeAll(try MirrorWire.encode(MirrorMessage(kind: .pong)), to: descriptor)
          continue
        }
        guard message.kind == .frame, let frame = message.frame, let sequence = message.sequence else {
          throw MirrorProtocolError.invalidMessage
        }
        // The formatter emits modes only when they differ from defaults. A full
        // reset prevents a prior frame's paste/cursor modes from leaking forward.
        var output = Data("\u{1b}c\u{1b}[?2026h".utf8)
        output.append(frame.bytes)
        output.append(Data("\u{1b}[?2026l".utf8))
        try writeAll(output, to: STDOUT_FILENO)
        try writeAll(try MirrorWire.encode(MirrorMessage(kind: .acknowledge, sequence: sequence)), to: descriptor)
      }
      if polls[1].revents & Int16(POLLIN) != 0 {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let readCount = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        guard readCount > 0 else { return }
        try writeAll(
          try MirrorWire.encode(MirrorMessage(kind: .input, bytes: Data(bytes.prefix(readCount)))), to: descriptor)
      }
      if polls.contains(where: { $0.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 }) { return }
    }
  }

  private static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
    var result = Data(count: count)
    try result.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < count {
        let amount = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
        if amount < 0, errno == EINTR { continue }
        guard amount > 0 else { throw MirrorProtocolError.invalidMessage }
        offset += amount
      }
    }
    return result
  }

  private static func writeAll(_ bytes: Data, to descriptor: Int32) throws {
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < bytes.count {
        let amount = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
        if amount < 0, errno == EINTR { continue }
        guard amount > 0 else { throw MirrorProtocolError.invalidMessage }
        offset += amount
      }
    }
  }
}
