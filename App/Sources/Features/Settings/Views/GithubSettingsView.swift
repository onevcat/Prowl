import ComposableArchitecture
import SwiftUI

@MainActor @Observable
final class GithubSettingsViewModel {
  enum State: Equatable {
    case loading
    case unavailable
    case outdated
    case notAuthenticated
    case authenticated(GithubAuthStatusSnapshot)
    case rateLimited(retryAt: Date)
    case error(String)
  }

  var state: State = .loading
  var rateLimitedUntil: Date?

  @ObservationIgnored
  @Dependency(GithubIntegrationClient.self) private var githubIntegration

  @ObservationIgnored
  @Dependency(GithubCLIClient.self) private var githubCLI

  // Follows the account's rate limit while the page is open, and reloads the account list once
  // GitHub accepts requests again if the limit kept it from loading.
  func observeRateLimit() async {
    for await retryAt in await githubCLI.rateLimitRetryTimes() {
      rateLimitedUntil = retryAt
      if retryAt == nil, case .rateLimited = state {
        await load()
      }
    }
  }

  func load() async {
    state = .loading
    let isAvailable = await githubIntegration.isAvailable()
    guard isAvailable else {
      state = .unavailable
      return
    }

    do {
      let snapshot = try await githubCLI.authStatusSnapshot()
      if snapshot.allAccounts.contains(where: { $0.active }) {
        state = .authenticated(snapshot)
      } else {
        state = .notAuthenticated
      }
    } catch let error as GithubCLIError {
      switch error {
      case .outdated:
        state = .outdated
      case .unavailable:
        state = .unavailable
      case .commandFailed(let message):
        state = .error(message)
      case .rateLimited(let retryAt):
        // The gate may have reopened while this load was in flight, after the observer already
        // saw the recovery; its current state decides between reloading and waiting for it.
        var gateState = await githubCLI.rateLimitRetryTimes().makeAsyncIterator()
        if case .some(.none) = await gateState.next() {
          await load()
          return
        }
        state = .rateLimited(retryAt: retryAt)
      }
    } catch {
      state = .error(error.localizedDescription)
    }
  }
}

struct GithubSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var viewModel = GithubSettingsViewModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Form {
        Section("GitHub integration") {
          Toggle(
            "Enable GitHub integration",
            isOn: $store.githubIntegrationEnabled
          )
          .help("Enable GitHub integration")
        }
        Section("GitHub CLI") {
          if let retryAt = viewModel.rateLimitedUntil, viewModel.state.isRateLimited == false {
            GithubRateLimitNotice(retryAt: retryAt)
          }
          switch viewModel.state {
          case .loading:
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text("Checking GitHub CLI...")
                .foregroundStyle(.secondary)
            }

          case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
              Label("GitHub integration unavailable", systemImage: "xmark.circle")
                .foregroundStyle(.red)
              Text("Enable GitHub integration and install gh CLI to use pull request checks.")
                .foregroundStyle(.secondary)
                .font(.callout)
            }

          case .notAuthenticated:
            VStack(alignment: .leading, spacing: 8) {
              Label("Not authenticated", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
              Text("Run `gh auth login` in terminal to authenticate.")
                .foregroundStyle(.secondary)
                .font(.callout)
            }

          case .outdated:
            VStack(alignment: .leading, spacing: 8) {
              Label("GitHub CLI outdated", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
              Text("Update GitHub CLI to the latest version to use GitHub integration.")
                .foregroundStyle(.secondary)
                .font(.callout)
            }

          case .authenticated(let snapshot):
            ForEach(snapshot.sortedHosts, id: \.self) { host in
              let accounts = snapshot.accounts(on: host)
              VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Host") {
                  Text(host)
                    .font(.body)
                }
                ForEach(accounts) { account in
                  HStack {
                    Text(account.login)
                    if account.active {
                      Text("Active")
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let status = GithubAuthAccountStatusDisplay(account.state) {
                      Text(status.title)
                        .foregroundStyle(status.style)
                        .help(status.help)
                    }
                  }
                  .font(.body)
                }
              }
            }

          case .rateLimited(let retryAt):
            GithubRateLimitNotice(retryAt: viewModel.rateLimitedUntil ?? retryAt)

          case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
              Label("Error checking status", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
              Text(message)
                .foregroundStyle(.secondary)
                .font(.callout)
            }
          }
        }
        Section("Pull Requests") {
          Picker(selection: $store.pullRequestMergeStrategy) {
            ForEach(PullRequestMergeStrategy.allCases) { strategy in
              Text(strategy.title).tag(strategy)
            }
          } label: {
            Text("Merge strategy")
            Text("Default strategy when merging PRs from the command palette.")
          }
        }
      }
      .formStyle(.grouped)

      switch viewModel.state {
      case .unavailable:
        HStack {
          Button("Get GitHub CLI") {
            NSWorkspace.shared.open(URL(string: "https://cli.github.com")!)
          }
          .help("Open GitHub CLI website")
          Spacer()
        }
        .padding(.top)
      case .outdated:
        HStack {
          Button("Update GitHub CLI") {
            NSWorkspace.shared.open(URL(string: "https://cli.github.com")!)
          }
          .help("Open GitHub CLI website")
          Spacer()
        }
        .padding(.top)
      default:
        EmptyView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      await viewModel.load()
    }
    .task {
      await viewModel.observeRateLimit()
    }
    .onChange(of: store.githubIntegrationEnabled) { _, _ in
      Task {
        await viewModel.load()
      }
    }
  }
}

extension GithubSettingsViewModel.State {
  var isRateLimited: Bool {
    if case .rateLimited = self { return true }
    return false
  }
}

private struct GithubRateLimitNotice: View {
  let retryAt: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        "GitHub rate-limited, retrying at \(retryAt, format: .dateTime.hour().minute())",
        systemImage: "exclamationmark.triangle"
      )
      .foregroundStyle(.orange)
      Text(
        """
        GitHub refused requests for this account's rate limit. Prowl sends none until the retry time, \
        so other tools on the account keep working.
        """
      )
      .foregroundStyle(.secondary)
      .font(.callout)
    }
  }
}

private struct GithubAuthAccountStatusDisplay {
  let title: String
  let help: String
  let style: Color

  init?(_ state: String?) {
    guard let state else { return nil }
    switch state.lowercased() {
    case "success":
      return nil
    case "timeout":
      title = String(localized: "Timed out")
      help = String(localized: "gh could not verify this account in time.")
      style = .orange
    case "error":
      title = String(localized: "Needs attention")
      help = String(localized: "gh could not verify this account.")
      style = .red
    default:
      title = String(localized: "Check failed")
      help = String(localized: "gh reported an authentication issue.")
      style = .orange
    }
  }
}
