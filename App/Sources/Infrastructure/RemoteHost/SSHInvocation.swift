import Foundation

/// The local `ssh` command line of a pane, read with an explicit grammar (docs-ai 082,
/// L0 item 2). Connection-shaping options become the side channel's recipe; forwarding,
/// session, and command options are dropped, because the side channel never replays them;
/// anything outside the grammar makes the pane `unsupported` instead of guessed.
nonisolated enum SSHInvocation: Equatable, Sendable {
  case supported(SSHConnectionRecipe)
  case unsupported(String)

  /// Flags that take no value and shape the connection.
  private static let replayedFlags: Set<Character> = ["4", "6", "C", "k", "q"]
  /// Options with a value that shape the connection.
  private static let replayedValues: Set<Character> = ["b", "B", "c", "F", "i", "I", "J", "l", "m", "p", "P"]
  /// Flags without a value that only affect the interactive session.
  private static let droppedFlags: Set<Character> = ["A", "a", "g", "K", "M", "n", "t", "T", "v", "x", "X", "y", "Y"]
  /// Options with a value that only affect the interactive session.
  private static let droppedValues: Set<Character> = ["D", "e", "E", "L", "R", "S", "w"]

  /// `-o` keys (lowercased) the side channel replays.
  static let replayedConfigKeys: Set<String> = [
    "addressfamily", "bindaddress", "bindinterface", "canonicaldomains", "canonicalizefallbacklocal",
    "canonicalizehostname", "canonicalizemaxdots", "canonicalizepermittedcnames", "casignaturealgorithms",
    "certificatefile", "checkhostip", "ciphers", "compression", "connectionattempts", "fingerprinthash",
    "globalknownhostsfile", "gssapiauthentication", "gssapidelegatecredentials", "hashknownhosts",
    "hostbasedacceptedalgorithms", "hostbasedauthentication", "hostkeyalgorithms", "hostkeyalias", "hostname",
    "identitiesonly", "identityagent", "identityfile", "ipqos", "kbdinteractiveauthentication",
    "kbdinteractivedevices", "kexalgorithms", "knownhostscommand", "macs", "nohostauthenticationforlocalhost",
    "numberofpasswordprompts", "passwordauthentication", "pkcs11provider", "port", "preferredauthentications",
    "proxycommand", "proxyjump", "proxyusefdpass", "pubkeyacceptedalgorithms", "pubkeyauthentication",
    "rekeylimit", "requiredrsasize", "revokedhostkeys", "securitykeyprovider", "serveralivecountmax",
    "serveraliveinterval", "streamlocalbindmask", "stricthostkeychecking", "tag", "tcpkeepalive",
    "updatehostkeys", "user", "userknownhostsfile", "verifyhostkeydns", "visualhostkey", "xauthlocation",
    "usekeychain", "addkeystoagent",
  ]
  /// `-o` keys (lowercased) that only shape the interactive session; dropped.
  static let droppedConfigKeys: Set<String> = [
    "clearallforwardings", "controlmaster", "controlpath", "controlpersist", "dynamicforward",
    "enableescapecommandline",
    "escapechar", "exitonforwardfailure", "forkafterauthentication", "forwardagent", "forwardx11",
    "forwardx11timeout", "forwardx11trusted", "gatewayports", "localcommand", "localforward", "logverbose",
    "obscurekeystroketiming", "permitlocalcommand", "permitremoteopen", "remotecommand", "remoteforward",
    "requesttty", "sessiontype", "stdinnull", "streamlocalbindunlink", "syslogfacility", "tunnel", "tunneldevice",
    "batchmode", "loglevel", "sendenv", "setenv",
    // With ControlPersist it holds the first command's output open; the runner bounds it.
    "connecttimeout",
  ]

  /// Parses `arguments` (argv without `ssh` itself).
  static func parse(_ arguments: [String]) -> SSHInvocation {
    var options: [String] = []
    var index = arguments.startIndex
    while index < arguments.endIndex {
      let argument = arguments[index]
      if argument == "--" {
        index += 1
        break
      }
      guard argument.hasPrefix("-"), argument.count > 1 else { break }
      var letters = argument.dropFirst()[...]
      while let letter = letters.popFirst() {
        if replayedFlags.contains(letter) {
          options.append("-\(letter)")
          continue
        }
        if droppedFlags.contains(letter) { continue }
        guard replayedValues.contains(letter) || droppedValues.contains(letter) || letter == "o" else {
          return .unsupported("ssh option -\(letter)")
        }
        // The value is the rest of this argument, or the next one.
        let value: String
        if !letters.isEmpty {
          value = String(letters)
          letters = ""
        } else {
          index += 1
          guard index < arguments.endIndex else { return .unsupported("ssh option -\(letter) without a value") }
          value = arguments[index]
        }
        if letter == "o" {
          switch configOption(value) {
          case .replayed: options += ["-o", value]
          case .dropped: break
          case .unsupported(let key): return .unsupported("ssh option -o \(key)")
          }
        } else if replayedValues.contains(letter) {
          options += ["-\(letter)", value]
        }
      }
      index += 1
    }
    guard index < arguments.endIndex, !arguments[index].isEmpty else { return .unsupported("no destination") }
    return .supported(SSHConnectionRecipe(destination: arguments[index], options: options))
  }

  private enum ConfigOption: Equatable {
    case replayed
    case dropped
    case unsupported(String)
  }

  /// `Key=value`, `Key value`, or `Key = value`, as `ssh -o` accepts them.
  private static func configOption(_ text: String) -> ConfigOption {
    let key = text.prefix { !$0.isWhitespace && $0 != "=" }.lowercased()
    if replayedConfigKeys.contains(key) { return .replayed }
    if droppedConfigKeys.contains(key) { return .dropped }
    return .unsupported(key.isEmpty ? text : key)
  }
}
