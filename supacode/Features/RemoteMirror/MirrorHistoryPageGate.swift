import Foundation

/// Every page must continue the same frozen snapshot, within one total budget.
nonisolated struct MirrorHistoryPageGate {
  private var id: UUID?
  private var total = 0
  private var offset = 0
  private var bytes = 0
  private var capturedAt: TimeInterval?

  mutating func accept(_ message: MirrorMessage, requiresTimestamp: Bool) -> Bool {
    guard let pageID = message.historyID, let pageOffset = message.offset,
      let pageTotal = message.total, let lines = message.lines,
      pageTotal >= 0, pageTotal <= MirrorHistory.maximumBytes + 1,
      pageOffset >= 0, pageOffset <= pageTotal, lines.count <= MirrorHistory.pageSize,
      pageOffset + lines.count == (id == nil ? pageTotal : offset),
      id == nil || (pageID == id && pageTotal == total && offset > 0),
      !lines.isEmpty || (id == nil && pageTotal == 0)
    else { return false }
    if requiresTimestamp {
      guard let timestamp = message.capturedAt, timestamp.isFinite,
        id == nil || timestamp == capturedAt
      else { return false }
    }
    var pageBytes = 0
    for line in lines {
      let size = line.utf8.count + 1
      guard size <= MirrorHistory.maximumBytes + 1 - bytes - pageBytes else { return false }
      pageBytes += size
    }
    id = pageID
    total = pageTotal
    offset = pageOffset
    capturedAt = message.capturedAt
    bytes += pageBytes
    return true
  }
}
