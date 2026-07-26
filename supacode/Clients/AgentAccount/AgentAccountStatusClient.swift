import ComposableArchitecture
import Foundation

/// Which login, if any, an agent account currently holds. Prowl never owns these
/// credentials — it only asks each CLI what it sees in that account's directory.
nonisolated struct AgentAccountStatus: Equatable, Sendable {
  nonisolated enum LoginState: Equatable, Sendable {
    case signedIn(String)
    case signedOut
    /// The CLI could not be asked: not installed, or an answer we cannot read.
    case unavailable
  }

  var claude: LoginState = .signedOut
  var codex: LoginState = .signedOut
}

nonisolated struct AgentAccountStatusClient: Sendable {
  var status: @Sendable (String) async -> AgentAccountStatus
}

nonisolated enum AgentAccountAuthAction: Equatable, Sendable {
  case signIn
  case signOut
}

nonisolated enum AgentAccountCLI: String, CaseIterable, Equatable, Sendable {
  case claude
  case codex

  var displayName: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    }
  }

  /// Carries the account directory itself, so the command acts on the chosen
  /// account no matter which account the pane running it resolves to.
  func command(_ action: AgentAccountAuthAction, forAccountNamed account: String) -> String? {
    let environment = AgentAccount.environment(forAccountNamed: account)
    switch self {
    case .claude:
      let verb = action == .signIn ? "login" : "logout"
      return environment["CLAUDE_CONFIG_DIR"].map { "CLAUDE_CONFIG_DIR=\(Self.quoted($0)) claude auth \(verb)" }
    case .codex:
      let verb = action == .signIn ? "login" : "logout"
      return environment["CODEX_HOME"].map { "CODEX_HOME=\(Self.quoted($0)) codex \(verb)" }
    }
  }

  private static func quoted(_ path: String) -> String {
    "'\(path.replacing("'", with: "'\"'\"'"))'"
  }
}

nonisolated extension AgentAccountStatus {
  private struct ClaudeAuthStatus: Decodable {
    let loggedIn: Bool
    let email: String?
    let orgName: String?
    let subscriptionType: String?
  }

  /// `claude auth status` prints JSON on both paths and exits non-zero when
  /// signed out, so the exit code says nothing — only the payload does.
  static func claudeState(fromOutput output: String) -> LoginState {
    guard let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
      let decoded = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: data)
    else {
      return .unavailable
    }
    guard decoded.loggedIn else { return .signedOut }
    let identity = decoded.email ?? decoded.orgName ?? "Signed in"
    guard let plan = decoded.subscriptionType, !plan.isEmpty else { return .signedIn(identity) }
    return .signedIn("\(identity) (\(plan))")
  }

  /// `codex login status` only reports whether a login exists; it never names the
  /// account.
  static func codexState(fromOutput output: String) -> LoginState {
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let line = text.split(separator: "\n").last.map(String.init), !line.isEmpty else {
      return .unavailable
    }
    if line.localizedCaseInsensitiveContains("not logged in") { return .signedOut }
    if line.localizedCaseInsensitiveContains("logged in") { return .signedIn(line) }
    return .unavailable
  }
}

nonisolated extension AgentAccountStatusClient {
  static func answer(stdout: String, stderr: String) -> String {
    stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stderr : stdout
  }

  static func live(shell: ShellClient) -> Self {
    Self { account in
      let environment = AgentAccount.environment(forAccountNamed: account)
      guard let claudeDirectory = environment["CLAUDE_CONFIG_DIR"],
        let codexDirectory = environment["CODEX_HOME"]
      else {
        return AgentAccountStatus(claude: .unavailable, codex: .unavailable)
      }

      // An account nobody has opened a pane for yet has no directory, and asking
      // `codex` about a missing CODEX_HOME is an error rather than an answer.
      // `claude` answers on stdout, `codex` on stderr, and both exit non-zero
      // when signed out, so neither the stream nor the exit code can be assumed.
      func output(directory: String, arguments: [String], variable: String) async -> String? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        do {
          let result = try await shell.runLogin(
            URL(fileURLWithPath: "/usr/bin/env"),
            ["\(variable)=\(directory)"] + arguments,
            nil,
            log: false
          )
          return Self.answer(stdout: result.stdout, stderr: result.stderr)
        } catch let error as ShellClientError {
          return Self.answer(stdout: error.stdout, stderr: error.stderr)
        } catch {
          return nil
        }
      }

      let claudeOutput = await output(
        directory: claudeDirectory,
        arguments: ["claude", "auth", "status"],
        variable: "CLAUDE_CONFIG_DIR"
      )
      let codexOutput = await output(
        directory: codexDirectory,
        arguments: ["codex", "login", "status"],
        variable: "CODEX_HOME"
      )
      return AgentAccountStatus(
        claude: claudeOutput.map { AgentAccountStatus.claudeState(fromOutput: $0) } ?? .signedOut,
        codex: codexOutput.map { AgentAccountStatus.codexState(fromOutput: $0) } ?? .signedOut
      )
    }
  }
}

extension AgentAccountStatusClient: DependencyKey {
  nonisolated static let liveValue = AgentAccountStatusClient.live(shell: .live)

  nonisolated static let testValue = AgentAccountStatusClient { _ in
    reportIssue("AgentAccountStatusClient.status is unimplemented")
    return AgentAccountStatus()
  }
}
