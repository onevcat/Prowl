// supacode/CLIService/CLIServiceStatus.swift
// Whether Prowl is listening for `prowl` on its socket (docs-ai 063 D1, deferred from C0).
// The socket server publishes it; Settings › CLI & Skills and the workflow start preflight
// read it, so a `prowl` that cannot connect is explained instead of looking healthy.

import ComposableArchitecture
import Foundation

nonisolated enum CLIServiceStatus: Equatable, Sendable {
  case stopped
  case listening(path: String)
  case failed(CLIServiceError, path: String)

  var isListening: Bool {
    if case .listening = self { return true }
    return false
  }

  /// Why `prowl` cannot reach this app right now — the preflight gate: nil only while listening.
  /// A stopped server is unreachable without being a failure (start-up, shutdown).
  var unreachableDescription: String? {
    switch self {
    case .listening: nil
    case .stopped: "Prowl is not listening for the prowl command right now."
    case .failed: failureDescription
    }
  }

  /// Why the last start failed; nil while listening or stopped.
  var failureDescription: String? {
    guard case .failed(let error, _) = self else { return nil }
    switch error {
    case .socketAlreadyOwned:
      return
        "Another Prowl instance is already listening on this socket. Quit it, or give this "
        + "instance its own path with PROWL_CLI_SOCKET."
    case .socketPathTooLong:
      return "The socket path is too long for macOS. Set PROWL_CLI_SOCKET to a shorter path."
    case .socketDirectoryUnavailable:
      return "Prowl could not create the socket's folder."
    case .lockFailed:
      return "Prowl could not lock the socket for this instance. Check the folder's permissions."
    case .permissionFailed:
      return "Prowl could not restrict the socket to your user. Check the folder's permissions."
    case .socketCreationFailed, .closeOnExecFailed:
      return "Prowl could not create the socket."
    case .bindFailed:
      return "Prowl could not bind the socket. Remove a stale file at this path and relaunch."
    case .listenFailed:
      return "Prowl could not start listening on the socket."
    case .readFailed, .writeFailed:
      return "The socket stopped responding."
    }
  }
}

/// The server writes here once on start (and on stop); readers see the latest value.
@MainActor
final class CLIServiceStatusPublisher {
  static let shared = CLIServiceStatusPublisher()

  private(set) var status: CLIServiceStatus = .stopped

  func publish(_ status: CLIServiceStatus) {
    self.status = status
  }
}

struct CLIServiceStatusClient: Sendable {
  var current: @MainActor @Sendable () -> CLIServiceStatus
}

extension CLIServiceStatusClient: DependencyKey {
  static let liveValue = CLIServiceStatusClient(current: { CLIServiceStatusPublisher.shared.status })

  /// Listening by default so features that merely read the status keep their existing tests.
  static let testValue = CLIServiceStatusClient(current: { .listening(path: "/tmp/prowl-test.sock") })
}
