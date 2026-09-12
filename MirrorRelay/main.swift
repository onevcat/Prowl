import Darwin
import Foundation
import MirrorRelayProtocol

enum MirrorRelay {
  private enum StreamEnd: Error { case closed }

  static func main() {
    let args = CommandLine.arguments
    guard args.count == 3, let port = UInt16(args[1]), port > 0 else { exit(2) }
    do {
      try run(port: port, token: args[2])
      exit(0)
    } catch StreamEnd.closed {
      exit(0)
    } catch {
      FileHandle.standardError.write(Data("Display relay failed: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func run(port: UInt16, token: String) throws {
    signal(SIGPIPE, SIG_IGN)
    var settings = termios()
    let isTerminal = isatty(STDIN_FILENO) == 1
    if isTerminal {
      guard tcgetattr(STDIN_FILENO, &settings) == 0 else {
        throw MirrorRelayPacket.Failure.invalidPacket
      }
      var raw = settings
      cfmakeraw(&raw)
      guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
        throw MirrorRelayPacket.Failure.invalidPacket
      }
    }
    defer { if isTerminal { _ = tcsetattr(STDIN_FILENO, TCSANOW, &settings) } }
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw MirrorRelayPacket.Failure.invalidPacket }
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
    guard connected == 0 else { throw MirrorRelayPacket.Failure.invalidPacket }
    try writeAll(
      try MirrorRelayPacket(kind: .authenticate, payload: Data(token.utf8)).encoded(),
      to: descriptor)
    var polls = [
      pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
      pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
    ]
    while true {
      let count = polls.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, 2, -1) }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw MirrorRelayPacket.Failure.invalidPacket }
      if polls[0].revents & Int16(POLLIN) != 0 {
        let header = try MirrorRelayPacket.header(readExactly(5, from: descriptor))
        if header.kind == .ping {
          try writeAll(try MirrorRelayPacket(kind: .pong, payload: Data()).encoded(), to: descriptor)
          continue
        }
        if header.kind == .pong { continue }
        guard header.kind == .frame, header.length >= 8 else {
          throw MirrorRelayPacket.Failure.invalidPacket
        }
        let payload = try readExactly(header.length, from: descriptor)
        let sequence = Data(payload.prefix(8))
        // The formatter emits modes only when they differ from defaults. A full
        // reset prevents a prior frame's paste/cursor modes from leaking forward.
        var output = Data("\u{1b}c\u{1b}[?2026h".utf8)
        output.append(payload.dropFirst(8))
        output.append(Data("\u{1b}[?2026l".utf8))
        try writeAll(output, to: STDOUT_FILENO)
        try writeAll(
          try MirrorRelayPacket(kind: .acknowledge, payload: sequence).encoded(), to: descriptor)
      }
      if polls[1].revents & Int16(POLLIN) != 0 {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let readCount = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        guard readCount > 0 else { return }
        try writeAll(
          try MirrorRelayPacket(kind: .input, payload: Data(bytes.prefix(readCount))).encoded(),
          to: descriptor)
      }
      if polls.contains(where: { $0.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 }) { return }
    }
  }

  private static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
    var result = Data(count: count)
    try result.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < count {
        let amount = Darwin.read(
          descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
        if amount < 0, errno == EINTR { continue }
        if amount == 0, offset == 0 { throw StreamEnd.closed }
        guard amount > 0 else { throw MirrorRelayPacket.Failure.invalidPacket }
        offset += amount
      }
    }
    return result
  }

  private static func writeAll(_ bytes: Data, to descriptor: Int32) throws {
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < bytes.count {
        let amount = Darwin.write(
          descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
        if amount < 0, errno == EINTR { continue }
        guard amount > 0 else { throw MirrorRelayPacket.Failure.invalidPacket }
        offset += amount
      }
    }
  }
}

MirrorRelay.main()
