import SwiftUI

struct ToolbarUpdateButton: View {
  let availableVersion: String?
  let isReadyToInstall: Bool
  let onActivate: () -> Void

  private var tooltip: String {
    if isReadyToInstall {
      if let availableVersion, !availableVersion.isEmpty {
        return String(localized: "Version \(availableVersion) has been downloaded. Click to relaunch and install.")
      }
      return String(localized: "An update has been downloaded. Click to relaunch and install.")
    }
    if let availableVersion, !availableVersion.isEmpty {
      return String(localized: "Version \(availableVersion) is available. Click to review and install.")
    }
    return String(localized: "A new version is available. Click to review and install.")
  }

  var body: some View {
    Button {
      onActivate()
    } label: {
      Image(systemName: "arrow.down.circle.fill")
        .foregroundStyle(Color("ProwlAccent"))
        .accessibilityHidden(true)
    }
    .help(tooltip)
    .accessibilityLabel(isReadyToInstall ? "Relaunch to install update" : "Install update")
  }
}
