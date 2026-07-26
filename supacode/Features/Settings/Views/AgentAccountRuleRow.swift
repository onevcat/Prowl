import SwiftUI

/// One directory-to-account mapping, with its own validation message so an
/// unusable account name is reported next to the field that holds it.
struct AgentAccountRuleRow: View {
  @Binding var rule: AgentAccountRule
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        TextField("Path", text: $rule.pathPrefix, prompt: Text("~/work"))
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: .infinity)
        TextField("Account", text: $rule.account, prompt: Text("work"))
          .textFieldStyle(.roundedBorder)
          .frame(width: 160)
        Button(action: onRemove) {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove this rule")
        .accessibilityLabel("Remove rule")
      }
      .labelsHidden()
      AgentAccountNameWarning(name: rule.account)
    }
  }
}
