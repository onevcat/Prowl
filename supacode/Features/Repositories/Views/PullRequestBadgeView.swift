import SwiftUI

enum PullRequestBadgeStyle {
  static let mergedColor = Color.purple
  static let openColor = Color.green
  static let closedColor = Color.orange
  static let queuedColor = Color.brown

  static func style(state: String?, number: Int?, isQueued: Bool = false) -> (text: String, color: Color)? {
    guard let state = state?.uppercased() else {
      return nil
    }
    switch state {
    case "MERGED":
      return (text: number.map { "#\($0)" } ?? "MERGED", color: mergedColor)
    case "OPEN":
      return (text: number.map { "#\($0)" } ?? "OPEN", color: isQueued ? queuedColor : openColor)
    case "CLOSED":
      return (text: number.map { "#\($0)" } ?? "CLOSED", color: closedColor)
    default:
      return nil
    }
  }

  static func helpText(state: String?, url: URL?) -> String {
    let state = state?.uppercased()
    switch state {
    case "MERGED":
      if url == nil {
        return String(localized: "Pull request merged")
      }
      return String(localized: "Open merged pull request on GitHub")
    case "OPEN":
      if url == nil {
        return String(localized: "Pull request open")
      }
      return String(localized: "Open pull request on GitHub")
    case "CLOSED":
      if url == nil {
        return String(localized: "Pull request closed")
      }
      return String(localized: "Open closed pull request on GitHub")
    default:
      if url == nil {
        return String(localized: "Pull request")
      }
      return String(localized: "Open pull request on GitHub")
    }
  }
}

struct PullRequestBadgeView: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.caption2)
      .foregroundStyle(color)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .fixedSize(horizontal: true, vertical: false)
      .overlay {
        RoundedRectangle(cornerRadius: 4)
          .stroke(color, lineWidth: 1)
      }
      .accessibilityLabel(text)
  }
}
