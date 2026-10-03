// ProwlCLI/Transport/SocketConnectionProbe.swift
// Shared Unix socket connection diagnostics for CLI transport and app launch.

import Foundation
import ProwlCLIShared

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

enum SocketConnectionProbe {
  enum Status: Equatable {
    case connected
    case appUnavailable(Failure)
    case permissionDenied(Failure)
    case transportFailed(Failure)

    var isConnected: Bool {
      self == .connected
    }

    func exitError() -> ExitError? {
      switch self {
      case .connected:
        nil
      case .appUnavailable(let failure):
        ExitError(code: CLIErrorCode.appNotRunning, message: failure.appUnavailableMessage)
      case .permissionDenied(let failure):
        ExitError(code: CLIErrorCode.socketPermissionDenied, message: failure.permissionDeniedMessage)
      case .transportFailed(let failure):
        ExitError(code: CLIErrorCode.transportFailed, message: failure.transportFailedMessage)
      }
    }

    var diagnosticMessage: String {
      switch self {
      case .connected:
        "connected"
      case .appUnavailable(let failure):
        failure.shortDiagnostic
      case .permissionDenied(let failure):
        failure.shortDiagnostic
      case .transportFailed(let failure):
        failure.shortDiagnostic
      }
    }
  }

  struct Failure: Equatable {
    enum Kind: Equatable {
      case socketCreation(errno: Int32)
      case pathTooLong(maximumLength: Int)
      case connect(errno: Int32)
    }

    let socketPath: String
    let kind: Kind

    var shortDiagnostic: String {
      switch kind {
      case .socketCreation(let errorNumber):
        "socket creation failed (\(Self.errnoDescription(errorNumber)))"
      case .pathTooLong(let maximumLength):
        "socket path is too long (max \(maximumLength) bytes)"
      case .connect(let errorNumber):
        "connect failed (\(Self.errnoDescription(errorNumber)))"
      }
    }

    var appUnavailableMessage: String {
      """
      Cannot connect to Prowl CLI socket at \(socketPath): app is not running or the socket is stale \
      (\(diagnosticDetail)). Start or restart Prowl, then retry.
      """
    }

    var permissionDeniedMessage: String {
      """
      Cannot connect to Prowl CLI socket at \(socketPath): permission denied (\(diagnosticDetail)). \
      If this command is running in a sandboxed agent, allow this Unix socket path in the sandbox profile, \
      run prowl outside the sandbox, or start both Prowl and prowl with the same PROWL_CLI_SOCKET path \
      that the sandbox can access.
      """
    }

    var transportFailedMessage: String {
      switch kind {
      case .pathTooLong(let maximumLength):
        """
        Cannot connect to Prowl CLI socket at \(socketPath): socket path is too long \
        (max \(maximumLength) bytes). If PROWL_CLI_SOCKET is set, choose a shorter path.
        """
      default:
        """
        Cannot connect to Prowl CLI socket at \(socketPath): transport failure (\(diagnosticDetail)). \
        Check PROWL_CLI_SOCKET and ensure it points to Prowl's Unix socket.
        """
      }
    }

    private var diagnosticDetail: String {
      switch kind {
      case .socketCreation(let errorNumber), .connect(let errorNumber):
        Self.errnoDescription(errorNumber)
      case .pathTooLong(let maximumLength):
        "path too long; max \(maximumLength) bytes"
      }
    }

    private static func errnoDescription(_ errorNumber: Int32) -> String {
      let name = errnoName(errorNumber)
      let message = strerror(errorNumber).map { String(cString: $0) } ?? "Unknown error"
      return "\(name): \(message)"
    }
  }

  static func check(socketPath: String) -> Status {
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
      return .transportFailed(Failure(socketPath: socketPath, kind: .socketCreation(errno: errno)))
    }
    defer { close(socketFD) }

    return connect(socketFD: socketFD, socketPath: socketPath)
  }

  static func connect(socketFD: Int32, socketPath: String) -> Status {
    let addr: sockaddr_un
    do {
      addr = try socketAddress(for: socketPath)
    } catch let error as SocketAddressError {
      switch error {
      case .pathTooLong(let maximumLength):
        return .transportFailed(Failure(socketPath: socketPath, kind: .pathTooLong(maximumLength: maximumLength)))
      }
    } catch {
      return .transportFailed(Failure(socketPath: socketPath, kind: .connect(errno: EINVAL)))
    }

    let result = withUnsafePointer(to: addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        systemConnect(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      return status(for: Failure(socketPath: socketPath, kind: .connect(errno: errno)))
    }
    return .connected
  }

  private static func status(for failure: Failure) -> Status {
    guard case .connect(let errorNumber) = failure.kind else {
      return .transportFailed(failure)
    }

    switch errorNumber {
    case ENOENT, ECONNREFUSED:
      return .appUnavailable(failure)
    case EPERM, EACCES:
      return .permissionDenied(failure)
    default:
      return .transportFailed(failure)
    }
  }

  private static func socketAddress(for socketPath: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let maxLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
    guard pathBytes.count <= maxLength else {
      throw SocketAddressError.pathTooLong(maximumLength: maxLength)
    }

    withUnsafeMutableBytes(of: &addr.sun_path) { sunPathPtr in
      for idx in 0..<pathBytes.count {
        sunPathPtr[idx] = pathBytes[idx]
      }
      sunPathPtr[pathBytes.count] = 0
    }
    return addr
  }

  private static func errnoName(_ errorNumber: Int32) -> String {
    switch errorNumber {
    case EACCES: "EACCES"
    case ECONNREFUSED: "ECONNREFUSED"
    case EINVAL: "EINVAL"
    case ENOENT: "ENOENT"
    case ENOTSOCK: "ENOTSOCK"
    case EPERM: "EPERM"
    default: "errno \(errorNumber)"
    }
  }

  private static func systemConnect(_ socketFD: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32
  {
    #if canImport(Darwin)
      Darwin.connect(socketFD, address, length)
    #else
      Glibc.connect(socketFD, address, length)
    #endif
  }
}

private enum SocketAddressError: Error {
  case pathTooLong(maximumLength: Int)
}
