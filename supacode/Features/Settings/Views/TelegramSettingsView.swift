import ComposableArchitecture
import SwiftUI

struct TelegramSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    VStack(alignment: .leading) {
      Form {
        Section("Telegram bot") {
          Toggle(
            "Enable Telegram bot",
            isOn: $store.telegramBotEnabled
          )
          .help("Start or stop the built-in Telegram bot")

          SecureField(
            "Bot token",
            text: $store.telegramBotToken
          )
          .textContentType(.password)
          .help("Telegram bot token from BotFather")

          LabeledContent("Allowed user IDs") {
            TextField(
              "123456789, 987654321",
              text: Binding(
                get: { store.telegramAllowedUserIDsText },
                set: { store.send(.setTelegramAllowedUserIDsText($0)) }
              ),
              axis: .vertical
            )
            .lineLimit(2...4)
            .help("Telegram user IDs that can control Prowl")
          }

          LabeledContent("Default read lines") {
            Stepper(value: $store.telegramDefaultReadLines, in: 1...500) {
              Text("\(store.telegramDefaultReadLines)")
                .monospacedDigit()
            }
          }
          .help("Default number of terminal lines returned by /read")

          Toggle(
            "Require explicit pane for send and key",
            isOn: $store.telegramRequireExplicitPaneForWrite
          )
          .help("Require /send and /key to name a pane instead of using the current focus")

          Label(
            "Pane and tab close commands always require an explicit target ID.",
            systemImage: "exclamationmark.triangle"
          )
          .font(.callout)
          .foregroundStyle(.secondary)

          HStack(spacing: 8) {
            Button("Test Connection") {
              store.send(.testTelegramConnectionButtonTapped)
            }
            .help("Call Telegram getMe with the configured bot token")
            .disabled(store.telegramConnectionStatus == .testing)

            telegramConnectionStatusView
          }
        }

        Section("Commands") {
          VStack(alignment: .leading, spacing: 6) {
            commandRow("/agents", "Show current agent roster.")
            commandRow("/list", "Show worktree, tab, and pane summary.")
            commandRow("/read <pane-id> [lines]", "Read recent terminal output.")
            commandRow("/focus <pane-id>", "Focus a pane in Prowl.")
            commandRow("/send <pane-id> <text>", "Send text and Enter to a pane.")
            commandRow("/key <pane-id> <token>", "Send a supported key token.")
            commandRow("/tab_create <worktree>", "Create a tab in a worktree.")
            commandRow("/pane_close <pane-id>", "Close a pane with normal confirmation policy.")
            commandRow("/tab_close <tab-id>", "Close a tab with normal confirmation policy.")
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var telegramConnectionStatusView: some View {
    switch store.telegramConnectionStatus {
    case .idle:
      EmptyView()
    case .testing:
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text("Testing...")
          .foregroundStyle(.secondary)
      }
    case .success(let label):
      Label("Connected as \(label)", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .failure(let message):
      Label(message, systemImage: "xmark.circle.fill")
        .foregroundStyle(.red)
    }
  }

  private func commandRow(_ command: String, _ description: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(command)
        .font(.body.monospaced())
      Text(description)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
  }
}
