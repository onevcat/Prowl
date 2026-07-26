import SwiftUI

/// Explains why a typed account name has no effect. The name itself is kept as
/// typed, so the warning is the only signal the user gets that it is unusable.
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
