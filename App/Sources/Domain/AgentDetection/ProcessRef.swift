import Darwin
import Foundation

/// The effective SSH target that a remote process belongs to (docs-ai 082, C1).
///
/// The values come from `ssh -G`, never from what the user typed: `-l alice` and `-l bob`
/// on one host are different keys, and an alias edit does not change the key. Resolution
/// and the side channel that uses it land with the connection owner.
nonisolated struct ConnectionKey: Hashable, Sendable, Codable {
  let user: String
  let hostname: String
  let port: Int
  /// The resolved `ProxyJump` chain, outermost hop first; empty for a direct connection.
  let jumpChain: [String]
  /// The `-F` configuration file, or nil for the default user and system files.
  let configFile: String?

  init(user: String, hostname: String, port: Int = 22, jumpChain: [String] = [], configFile: String? = nil) {
    self.user = user
    self.hostname = hostname
    self.port = port
    self.jumpChain = jumpChain
    self.configFile = configFile
  }
}

/// A process on a remote host, as one probe snapshot reported it (docs-ai 082, C2).
///
/// `bootID` and `startToken` are the host's native values (Linux: `boot_id` and start
/// ticks; macOS: `kern.boottime` and `lstart`). Equality is generation equality: a
/// reused pid with another start token is another process. Nothing here is derived
/// from local receive time.
nonisolated struct RemoteProcessRef: Hashable, Sendable {
  let connection: ConnectionKey
  let bootID: String
  let pid: Int32
  let startToken: String
}

/// Where a process runs. Only `.local` values may reach code that reads local OS
/// state (libproc, file descriptors, pid-keyed files); such code takes a `pid_t` or
/// `LocalProcessGeneration` that only `localPID` and `LocalProcessGeneration` produce.
nonisolated enum ProcessRef: Hashable, Sendable {
  case local(pid_t)
  case remote(RemoteProcessRef)

  var localPID: pid_t? {
    guard case .local(let pid) = self else { return nil }
    return pid
  }

  /// The pid inside its own host's namespace. Use it only to relate processes of one
  /// job (parent links) or for display; never to read OS state.
  var namespacePID: Int32 {
    switch self {
    case .local(let pid): pid
    case .remote(let remote): remote.pid
    }
  }

  var origin: ProcessOrigin {
    switch self {
    case .local: .local
    case .remote(let remote): .remote(remote.connection)
    }
  }
}

/// The execution origin of a process. A change of origin (local ↔ remote, or another
/// connection key) retires all evidence of the previous process, including launch
/// context that otherwise survives an engine replacement.
nonisolated enum ProcessOrigin: Hashable, Sendable {
  case local
  case remote(ConnectionKey)
}

extension ProcessRef: CustomStringConvertible {
  var description: String {
    switch self {
    case .local(let pid): "\(pid)"
    case .remote(let remote): "\(remote.connection.hostname):\(remote.pid)"
    }
  }
}

/// A local process generation: a pid plus the start time libproc reports for it. Only
/// local OS readers take this type, so a remote reference cannot compile into them.
nonisolated struct LocalProcessGeneration: Equatable, Hashable, Sendable {
  let pid: pid_t
  let startedAt: Date
}

/// The process generation that agent evidence is bound to. Local generations compare
/// pid and start time, as before; remote generations compare the whole remote reference.
nonisolated enum AgentProcessGeneration: Equatable, Hashable, Sendable {
  case local(LocalProcessGeneration)
  case remote(RemoteProcessRef)

  static func local(pid: pid_t, startedAt: Date) -> AgentProcessGeneration {
    .local(LocalProcessGeneration(pid: pid, startedAt: startedAt))
  }

  var localGeneration: LocalProcessGeneration? {
    guard case .local(let generation) = self else { return nil }
    return generation
  }

  var origin: ProcessOrigin {
    switch self {
    case .local: .local
    case .remote(let remote): .remote(remote.connection)
    }
  }
}
