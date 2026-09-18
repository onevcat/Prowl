import Foundation

nonisolated enum AutoDeletePeriod: Int, Codable, CaseIterable, Comparable, Sendable, Identifiable {
  #if DEBUG
    case immediately = 0
  #endif
  case oneDay = 1
  case threeDays = 3
  case sevenDays = 7
  case fourteenDays = 14
  case thirtyDays = 30

  var id: Int { rawValue }

  var label: String {
    switch self {
    #if DEBUG
      case .immediately: String(localized: "Immediately (debug)")
    #endif
    case .oneDay: String(localized: "After 1 day")
    case .threeDays: String(localized: "After 3 days")
    case .sevenDays: String(localized: "After 7 days")
    case .fourteenDays: String(localized: "After 14 days")
    case .thirtyDays: String(localized: "After 30 days")
    }
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}
