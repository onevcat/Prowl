import CryptoKit
import Foundation

/// How to reach a host: the destination and the connection-shaping options of an `ssh`
/// command line (docs-ai 082, C1/C4). It carries no forwarding, session, or command option;
/// the side channel adds its own overrides on top.
nonisolated struct SSHConnectionRecipe: Hashable, Sendable, Codable {
  let destination: String
  /// Options in `ssh` order (`-p`, `2222`, `-o`, `IdentityFile=…`), already filtered to the
  /// supported connection-shaping set.
  let options: [String]

  init(destination: String, options: [String] = []) {
    self.destination = destination
    self.options = options
  }

  /// The `-F` file the options name, if any; part of the connection key.
  var configFile: String? {
    guard let index = options.firstIndex(of: "-F"), options.indices.contains(index + 1) else { return nil }
    return options[index + 1]
  }
}

/// A persistent host (docs-ai 082, C1). Persisted data refers to `id`; `alias` is only
/// shown; `recipe` still resolves through `~/.ssh/config`, so it is re-resolved with
/// `ssh -G` before use and compared with the key it was bound to.
nonisolated struct HostProfile: Identifiable, Hashable, Sendable, Codable {
  let id: UUID
  var alias: String
  var recipe: SSHConnectionRecipe
  /// The effective target the profile was last bound to.
  var connectionKey: ConnectionKey

  /// A resolution that reaches another user, hostname, or port (for example an edited
  /// `HostName`) is a different authority: operations pause until the user rebinds the
  /// profile or keeps the old target.
  func authorityChanged(to resolved: ConnectionKey) -> Bool {
    resolved.user != connectionKey.user || resolved.hostname != connectionKey.hostname
      || resolved.port != connectionKey.port
  }
}

/// The argument vectors Prowl runs for a host. Every side channel invocation overrides the
/// session effects a configuration may add, so a `LocalForward`, `RemoteCommand`, or
/// `LocalCommand` in `~/.ssh/config` never runs for it. `ssh` keeps the first value it
/// obtains for an option and reads the command line before any file, so these come first.
/// There is no `ConnectTimeout`: with `ControlPersist` it holds the first command's output
/// open for about ten seconds (OpenSSH 10.3); the runner's deadline bounds the whole command.
nonisolated enum SSHSideChannel {
  static let sessionOverrides: [String] = [
    "-o", "BatchMode=yes",
    "-o", "ClearAllForwardings=yes",
    "-o", "RemoteCommand=none",
    "-o", "RequestTTY=no",
    "-o", "PermitLocalCommand=no",
    "-o", "ForwardAgent=no",
    "-o", "ForwardX11=no",
    "-o", "Tunnel=no",
    "-o", "SessionType=default",
    "-o", "ForkAfterAuthentication=no",
    "-o", "StdinNull=no",
    "-o", "EscapeChar=none",
    "-o", "LogLevel=ERROR",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=2",
  ]

  /// `ssh … <destination> sh -s`: the script arrives on stdin, so the remote login shell
  /// (zsh, bash, fish) never parses Prowl's text.
  static func scriptArguments(recipe: SSHConnectionRecipe, controlPath: String, persist: Int) -> [String] {
    sessionOverrides
      + ["-o", "ControlMaster=auto", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=\(persist)", "-T"]
      + recipe.options + ["--", recipe.destination, "sh", "-s"]
  }

  /// `ssh -G …`: the effective configuration, without connecting.
  static func resolveArguments(recipe: SSHConnectionRecipe) -> [String] {
    ["-G"] + recipe.options + ["--", recipe.destination]
  }

  /// A short private socket path. `sun_path` holds 104 bytes on Darwin, so the key is
  /// hashed rather than spelled out.
  static func controlPath(for key: ConnectionKey, directory: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = (try? encoder.encode(key)) ?? Data()
    let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    return (directory as NSString).appendingPathComponent("cm-\(digest)")
  }
}

extension ConnectionKey {
  /// The key from `ssh -G` output. Nil when a field the key needs is missing.
  nonisolated init?(effectiveConfiguration text: String, configFile: String?) {
    var values: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: " ", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let name = parts[0].lowercased()
      if values[name] == nil { values[name] = String(parts[1]) }
    }
    guard let user = values["user"], let hostname = values["hostname"],
      let port = values["port"].flatMap(Int.init)
    else { return nil }
    let jump = values["proxyjump"].map { $0 == "none" ? [] : $0.split(separator: ",").map(String.init) } ?? []
    self.init(user: user, hostname: hostname, port: port, jumpChain: jump, configFile: configFile)
  }
}
