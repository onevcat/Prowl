import SwiftUI

/// Why a typed account name has no effect. The name is kept as typed, so this is
/// the only signal that it is unusable.
struct AgentAccountNameWarning: View {
  let name: String

  var body: some View {
    if !name.isEmpty, AgentAccount.normalizedName(name) == nil {
      Label(
        "\"\(name)\" cannot be an account name: no \"/\", \".\" or \"..\". This value is ignored.",
        systemImage: "exclamationmark.triangle"
      )
      .foregroundStyle(.secondary)
      .font(.callout)
    }
  }
}
