/// Proportional size of text in the app chrome and its sheets, as a multiple
/// of the system size. Distinct from `MinimumTextSize`, and the two answer
/// different questions.
///
/// A floor lifts anything below it to exactly itself, so it necessarily
/// compresses: at a 16pt floor, caption through headline all resolve to 16 and
/// stop being distinguishable. That is the correct behaviour for an
/// accessibility floor and the wrong behaviour for "make the interface
/// bigger", which has to keep the ramp intact.
///
/// This setting scales every style by the same factor, so the ordering and the
/// relative gaps survive. The floor is applied after it, which means a reader
/// can raise everything proportionally, put a hard lower bound under the
/// result, or do both.
///
/// Terminal content is excluded from both: its size comes from the Ghostty
/// font settings.
enum InterfaceTextScale: String, CaseIterable, Identifiable, Codable, Sendable {
  case system
  case percent110 = "110"
  case percent125 = "125"
  case percent150 = "150"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system:
      return "System"
    default:
      return "\(rawValue)%"
    }
  }

  /// The multiplier applied to every style's system size.
  var factor: Double {
    switch self {
    case .system:
      return 1
    default:
      return (Double(rawValue) ?? 100) / 100
    }
  }
}
