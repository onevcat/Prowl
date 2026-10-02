import SwiftUI

/// Renders the repository display label, preferring a user-defined
/// `customTitle` over the folder-derived `fallbackName`.
///
/// Stateless on purpose: the source of truth for `customTitle` lives
/// in `RepositoriesFeature.State.repositoryCustomTitles` (refreshed by
/// the reducer when settings change), so display sites read a plain
/// string and avoid per-row `@Shared(.repositorySettings(...))`
/// subscriptions on the hot path. Callers apply their own font /
/// foreground style modifiers — this view stays appearance-agnostic.
struct RepoDisplayName: View {
  let fallbackName: String
  var customTitle: String?
  var tooltip: String?

  var body: some View {
    Text(customTitle ?? fallbackName)
      .lineLimit(1)
      .truncationMode(.tail)
      .help(tooltip ?? "")
  }
}
