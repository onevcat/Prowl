import CoreGraphics

enum CanvasNavigationDirection: Equatable, Sendable {
  case moveUp, moveDown, moveLeft, moveRight
}

enum CanvasSpatialNavigation {
  struct CardEntry {
    var id: String
    var center: CGPoint
  }

  static func nearest(
    from currentID: String,
    direction: CanvasNavigationDirection,
    cards: [CardEntry]
  ) -> String? {
    guard let current = cards.first(where: { $0.id == currentID }) else {
      return nil
    }

    let candidates = cards.filter { candidate in
      guard candidate.id != currentID else { return false }
      switch direction {
      case .moveUp: return candidate.center.y < current.center.y
      case .moveDown: return candidate.center.y > current.center.y
      case .moveLeft: return candidate.center.x < current.center.x
      case .moveRight: return candidate.center.x > current.center.x
      }
    }

    return candidates.min(by: { lhs, rhs in
      score(from: current.center, to: lhs.center, direction: direction)
        < score(from: current.center, to: rhs.center, direction: direction)
    })?.id
  }

  private static func score(
    from origin: CGPoint,
    to target: CGPoint,
    direction: CanvasNavigationDirection
  ) -> CGFloat {
    let deltaX = abs(target.x - origin.x)
    let deltaY = abs(target.y - origin.y)
    switch direction {
    case .moveUp, .moveDown:
      return deltaY + deltaX * 2
    case .moveLeft, .moveRight:
      return deltaX + deltaY * 2
    }
  }
}
