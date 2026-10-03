import CoreGraphics

/// A live reading position: a document row and the distance from the top of that row to the
/// top of the visible area. When a pane switch creates the reading view again, `LazyVStack`
/// estimates the heights of the rows that it has not laid out, so an absolute scroll offset
/// does not show the same text again.
nonisolated struct MirrorReadingAnchor: Equatable {
  let row: MirrorDocument.Row.ID
  let offset: CGFloat
}

extension MirrorReadingAnchor {
  /// Makes the anchor for the visible top `top` from the content tops of the rows that are laid
  /// out: the last row that starts at or above `top`, else the first row below it.
  nonisolated init?(top: CGFloat, rowTops: [MirrorDocument.Row.ID: CGFloat]) {
    let rows = rowTops.map { ($0.value, $0.key) }
    guard let (rowTop, row) = rows.filter({ $0.0 <= top }).max(by: <) ?? rows.min(by: <) else {
      return nil
    }
    self.init(row: row, offset: top - rowTop)
  }
}
