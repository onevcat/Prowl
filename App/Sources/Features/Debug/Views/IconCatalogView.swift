import SwiftUI

#if DEBUG

  /// DEBUG-only catalogue of the auto-detected tab icons. Each row
  /// renders a `CommandIconMap` entry through the same `TabIconImage`
  /// the actual tab UI uses, so the asset / SF Symbol fallback / size
  /// behaviour shown here matches what users see on a real tab.
  ///
  /// `.searchable` puts the filter field in the window toolbar
  /// (NavigationSplitView's detail toolbar slot on macOS). Filtering
  /// is a case-insensitive substring match on the token, so typing
  /// `git` surfaces `git`, `gh`, `lazygit`, …
  struct IconCatalogView: View {
    @State private var searchText: String = ""

    var body: some View {
      let entries = filteredEntries
      ScrollView {
        if entries.isEmpty {
          ContentUnavailableView.search(text: searchText)
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
          LazyVStack(spacing: 0) {
            ForEach(entries, id: \.token) { entry in
              IconCatalogRow(token: entry.token, icon: entry.icon)
              Divider().padding(.leading, 60)
            }
          }
          .padding(.horizontal)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .searchable(text: $searchText, placement: .toolbar, prompt: "Filter commands")
    }

    private var filteredEntries: [(token: String, icon: TabIconSource)] {
      let all = CommandIconMap.debugAllEntries
      let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !needle.isEmpty else { return all }
      return all.filter { $0.token.localizedCaseInsensitiveContains(needle) }
    }
  }

  private struct IconCatalogRow: View {
    let token: String
    let icon: TabIconSource

    var body: some View {
      HStack(spacing: 16) {
        TabIconImage(rawName: icon.storageString, pointSize: 24)
          .foregroundStyle(.primary)
          .frame(width: 32, height: 32, alignment: .center)
        VStack(alignment: .leading, spacing: 2) {
          Text(token)
            .font(.body.monospaced().weight(.semibold))
          Text(detailLine)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 10)
    }

    private var detailLine: String {
      if let asset = icon.assetName {
        return "asset:\(asset)  ·  fallback sf:\(icon.systemSymbol)"
      }
      return "sf:\(icon.systemSymbol)"
    }
  }

#endif
