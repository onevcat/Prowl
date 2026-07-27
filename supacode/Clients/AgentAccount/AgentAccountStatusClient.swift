import ComposableArchitecture
import Foundation

/// Which login an agent account holds, as reported by each CLI.
nonisolated struct AgentAccountStatus: Equatable, Sendable {
  nonisolated enum LoginState: Equatable, Sendable {
    case signedIn(String)
    case signedOut
    /// The CLI could not be asked: not installed, an account name that resolves
    /// to no directory, or an unreadable answer.
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

  /// Carries the account directory, so the command acts on the chosen account
  /// whatever the pane running it resolves to.
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

  /// `claude auth status` exits non-zero when signed out but still prints JSON,
  /// so only the payload is meaningful.
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

      // `codex` errors on a missing CODEX_HOME, answers on stderr where `claude`
      // answers on stdout, and both exit non-zero when signed out.
      func state(
        directory: String,
        arguments: [String],
        variable: String,
        parse: (String) -> AgentAccountStatus.LoginState
      ) async -> AgentAccountStatus.LoginState {
        guard FileManager.default.fileExists(atPath: directory) else { return .signedOut }
        do {
          let result = try await shell.runLogin(
            URL(fileURLWithPath: "/usr/bin/env"),
            ["\(variable)=\(directory)"] + arguments,
            nil,
            log: false
          )
          return parse(Self.answer(stdout: result.stdout, stderr: result.stderr))
        } catch let error as ShellClientError {
          return parse(Self.answer(stdout: error.stdout, stderr: error.stderr))
        } catch {
          // The process never ran, so the state is unknown rather than signed out.
          return .unavailable
        }
      }

      return AgentAccountStatus(
        claude: await state(
          directory: claudeDirectory,
          arguments: ["claude", "auth", "status"],
          variable: "CLAUDE_CONFIG_DIR",
          parse: AgentAccountStatus.claudeState(fromOutput:)
        ),
        codex: await state(
          directory: codexDirectory,
          arguments: ["codex", "login", "status"],
          variable: "CODEX_HOME",
          parse: AgentAccountStatus.codexState(fromOutput:)
        )
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
