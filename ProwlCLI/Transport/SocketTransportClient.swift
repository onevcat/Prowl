// ProwlCLI/Transport/SocketTransportClient.swift
// Unix domain socket client for communicating with running Prowl app.

import Foundation
import ProwlCLIShared

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

enum SocketTransportClient {
  private static let maximumResponseLength = WorkflowSizeLimits.transportFrame

  /// Send a command envelope to the Prowl app and receive a response.
  static func send(
    _ envelope: CommandEnvelope,
    timeoutMilliseconds: Int? = nil
  ) throws -> Data {
    let socketPath = ProwlSocket.defaultPath

    // Encode request
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let requestData = try encoder.encode(envelope)

    // Create socket
    let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard clientFD >= 0 else {
      throw ExitError(
        code: CLIErrorCode.transportFailed,
        message: "Failed to create socket."
      )
    }
    defer { close(clientFD) }
    try configureNoSigPipe(clientFD)
    let deadline = timeoutMilliseconds.map {
      DispatchTime.now().uptimeNanoseconds + UInt64(max(1, $0)) * 1_000_000
    }
    if let timeoutMilliseconds {
      try configureTimeout(clientFD, milliseconds: timeoutMilliseconds)
    }

    let connection = SocketConnectionProbe.connect(socketFD: clientFD, socketPath: socketPath)
    if let error = connection.exitError() {
      throw error
    }

    // Send length-prefixed request: 4-byte big-endian length + JSON payload
    var length = UInt32(requestData.count).bigEndian
    try withUnsafeBytes(of: &length) {
      try fdWrite(fildes: clientFD, buffer: $0, deadline: deadline)
    }
    try requestData.withUnsafeBytes {
      try fdWrite(fildes: clientFD, buffer: $0, deadline: deadline)
    }

    // Read length-prefixed response
    let responseLengthData = try fdRead(fildes: clientFD, count: 4, deadline: deadline)
    let responseLength = responseLengthData.withUnsafeBytes {
      UInt32(bigEndian: $0.load(as: UInt32.self))
    }

    guard responseLength > 0, responseLength <= maximumResponseLength else {
      throw ExitError(
        code: CLIErrorCode.transportFailed,
        message: "Invalid response length from app."
      )
    }

    return try fdRead(fildes: clientFD, count: Int(responseLength), deadline: deadline)
  }

  // MARK: - Low-level I/O using Darwin/Glibc read/write

  private static func configureNoSigPipe(_ descriptor: Int32) throws {
    #if canImport(Darwin)
      var enabled: Int32 = 1
      let result = withUnsafePointer(to: &enabled) {
        setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_NOSIGPIPE,
          $0,
          socklen_t(MemoryLayout<Int32>.size)
        )
      }
      guard result == 0 else {
        throw ExitError(code: CLIErrorCode.transportFailed, message: "Failed to configure socket safety.")
      }
    #endif
  }

  private static func configureTimeout(_ descriptor: Int32, milliseconds: Int) throws {
    let bounded = max(1, milliseconds)
    var timeout = timeval(
      tv_sec: bounded / 1_000,
      tv_usec: Int32((bounded % 1_000) * 1_000)
    )
    let size = socklen_t(MemoryLayout<timeval>.size)
    let receive = withUnsafePointer(to: &timeout) {
      setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, size)
    }
    let send = withUnsafePointer(to: &timeout) {
      setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, size)
    }
    guard receive == 0, send == 0 else {
      throw ExitError(code: CLIErrorCode.transportFailed, message: "Failed to configure socket deadline.")
    }
  }

  private static func fdWrite(
    fildes: Int32,
    buffer: UnsafeRawBufferPointer,
    deadline: UInt64?
  ) throws {
    var offset = 0
    while offset < buffer.count {
      try waitUntilReady(fildes, events: Int16(POLLOUT), deadline: deadline)
      let written = Darwin.write(fildes, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
      guard written > 0 else {
        throw ExitError(code: CLIErrorCode.transportFailed, message: socketWriteFailureMessage(bytesWritten: written))
      }
      offset += written
    }
  }

  private static func fdRead(
    fildes: Int32,
    count: Int,
    deadline: UInt64?
  ) throws -> Data {
    var data = Data(capacity: count)
    var remaining = count
    let bufferSize = min(count, 65536)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
    defer { buffer.deallocate() }
    while remaining > 0 {
      try waitUntilReady(fildes, events: Int16(POLLIN), deadline: deadline)
      let toRead = min(remaining, bufferSize)
      let bytesRead = Darwin.read(fildes, buffer, toRead)
      guard bytesRead > 0 else {
        throw ExitError(code: CLIErrorCode.transportFailed, message: socketReadFailureMessage(bytesRead: bytesRead))
      }
      data.append(buffer.assumingMemoryBound(to: UInt8.self), count: bytesRead)
      remaining -= bytesRead
    }
    return data
  }

  private static func waitUntilReady(
    _ descriptor: Int32,
    events: Int16,
    deadline: UInt64?
  ) throws {
    guard let deadline else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    guard now < deadline else { throw deadlineError() }
    let remainingMilliseconds = max(1, Int((deadline - now + 999_999) / 1_000_000))
    var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
    let result = poll(&pollDescriptor, 1, Int32(min(remainingMilliseconds, Int(Int32.max))))
    guard result > 0 else { throw deadlineError() }
  }

  private static func deadlineError() -> ExitError {
    ExitError(
      code: CLIErrorCode.transportFailed,
      message: "Prowl hook transport exceeded its total deadline."
    )
  }

  private static func socketWriteFailureMessage(bytesWritten: Int) -> String {
    if bytesWritten == 0 {
      return "Socket write failed: wrote 0 bytes before the request was complete."
    }
    return "Socket write failed (\(errnoName(errno)): \(String(cString: strerror(errno))))."
  }

  private static func socketReadFailureMessage(bytesRead: Int) -> String {
    if bytesRead == 0 {
      return "Socket read failed: Prowl closed the connection before sending a complete response."
    }
    return "Socket read failed (\(errnoName(errno)): \(String(cString: strerror(errno))))."
  }

  private static func errnoName(_ errorNumber: Int32) -> String {
    switch errorNumber {
    case EACCES: "EACCES"
    case ECONNREFUSED: "ECONNREFUSED"
    case EINVAL: "EINVAL"
    case ENOENT: "ENOENT"
    case ENOTSOCK: "ENOTSOCK"
    case EPIPE: "EPIPE"
    case EPERM: "EPERM"
    default: "errno \(errorNumber)"
    }
  }
}
