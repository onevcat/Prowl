import Foundation

/// Finds where a web link that was cut out of prose really ends.
///
/// A GFM extended autolink ends only at whitespace or `<`, and only ASCII
/// punctuation is trimmed from its end. In CJK prose a URL is rarely followed
/// by a space, so in `PR #1（https://example.com/1）里，好。` the link takes in
/// `）里，好。` and opens a page that does not exist. Foundation Markdown and
/// the OSC 8 links that agent CLIs print follow this rule.
nonisolated enum ProseURLTrimmer {
  /// `url` up to its first non-ASCII punctuation or space character.
  ///
  /// Only `http` and `https` URLs change: an unencoded full-width comma or
  /// paren in a web URL almost always comes from the sentence around it.
  /// Non-ASCII letters such as `https://zh.wikipedia.org/wiki/猫` stay, and
  /// `url` is returned unchanged when the cut would leave no host.
  static func trimmed(_ url: String) -> String {
    guard let separator = url.firstRange(of: "://") else { return url }
    let scheme = url[..<separator.lowerBound].lowercased()
    guard scheme == "http" || scheme == "https" else { return url }

    let rest = url[separator.upperBound...]
    guard let cut = rest.unicodeScalars.firstIndex(where: endsProseURL) else { return url }
    guard cut > rest.startIndex else { return url }
    return String(url.unicodeScalars[..<cut])
  }

  private static func endsProseURL(_ scalar: Unicode.Scalar) -> Bool {
    guard !scalar.isASCII else { return false }
    switch scalar.properties.generalCategory {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
      .initialPunctuation, .finalPunctuation, .otherPunctuation, .spaceSeparator:
      return true
    default:
      return false
    }
  }
}
