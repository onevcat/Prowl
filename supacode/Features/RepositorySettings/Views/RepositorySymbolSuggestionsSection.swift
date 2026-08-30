import SwiftUI

/// "Suggested for this repository" block inside the repository symbol
/// picker sheet. Renders the whole suggestion lifecycle: an idle state
/// with an explicit Suggest button, an inline loading state that never
/// blocks manual selection, and the finished results with the best
/// pick, alternates, the reasoning line, and an honest source label.
struct RepositorySymbolSuggestionsSection: View {
  let phase: RepositorySettingsFeature.SymbolSuggestionsPhase
  /// Starts a run (idle/failed) or re-runs generation (loaded).
  let onSuggest: () -> Void
  /// Fills the picker's symbol field with the tapped suggestion; the
  /// user still confirms with the sheet's Done button.
  let onPick: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("Suggested for this repository")
          .interfaceFont(.subheadline, weight: .medium)
        Spacer(minLength: 0)
        switch phase {
        case .idle:
          suggestButton(title: "Suggest", help: "Suggest SF Symbols for this repository using on-device intelligence.")
        case .loading:
          EmptyView()
        case .loaded:
          suggestButton(title: "Regenerate", help: "Run the on-device suggestion again for fresh candidates.")
        case .failed:
          suggestButton(title: "Retry", help: "Try generating suggestions again.")
        }
      }
      switch phase {
      case .idle:
        Text("Uses this project's README to propose fitting symbols. Everything runs on-device.")
          .interfaceFont(.caption)
          .foregroundStyle(.secondary)
      case .loading:
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Generating suggestions…")
            .interfaceFont(.caption)
            .foregroundStyle(.secondary)
        }
      case .loaded(let suggestions):
        loadedContent(suggestions)
      case .failed:
        Text("Couldn't generate suggestions. You can retry, or pick a symbol manually below.")
          .interfaceFont(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.secondary.opacity(0.08))
    )
  }

  @ViewBuilder
  private func loadedContent(_ suggestions: RepositorySymbolSuggestions) -> some View {
    HStack(spacing: 6) {
      ForEach(suggestions.allSymbols, id: \.self) { symbol in
        Button {
          onPick(symbol)
        } label: {
          Image(systemName: symbol)
            .imageScale(.medium)
            .frame(width: 32, height: 32)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                  symbol == suggestions.primary ? Color.accentColor.opacity(0.6) : Color.clear,
                  lineWidth: 1.5
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .help(symbol)
        .accessibilityLabel(symbol == suggestions.primary ? "\(symbol), best match" : symbol)
        .accessibilityHint("Fills the symbol name field with this suggestion.")
      }
      Spacer(minLength: 0)
    }
    Text(suggestions.reason)
      .interfaceFont(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(3)
      .fixedSize(horizontal: false, vertical: true)
    Text(sourceLabel(suggestions))
      .interfaceFont(.caption2)
      .foregroundStyle(.tertiary)
  }

  private func sourceLabel(_ suggestions: RepositorySymbolSuggestions) -> String {
    // Retrieval-only fallbacks must never masquerade as model output.
    suggestions.usedAI
      ? suggestions.source.disclosureLabel
      : "Keyword suggestions · \(suggestions.source.disclosureLabel)"
  }

  @ViewBuilder
  private func suggestButton(title: String, help: String) -> some View {
    Button(title) {
      onSuggest()
    }
    .controlSize(.small)
    .help(help)
  }
}
