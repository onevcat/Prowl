import Foundation

nonisolated enum MirrorTextLayout {
  static let maximumScalars = 4096
  static let maximumLines = 32

  struct Chunk: Identifiable {
    let id: Int
    let raw: String
    let display: String
  }

  static func chunks(_ text: String) -> [Chunk] {
    var pieces: [String] = []
    var pending = ""
    var scalars = 0
    var lines = 0
    for scalar in text.unicodeScalars {
      pending.unicodeScalars.append(scalar)
      scalars += 1
      if scalar == "\n" { lines += 1 }
      if scalars >= maximumScalars || lines >= maximumLines {
        pieces.append(pending)
        pending = ""
        scalars = 0
        lines = 0
      }
    }
    if !pending.isEmpty || pieces.isEmpty { pieces.append(pending) }
    return pieces.enumerated().map { index, raw in
      // Adjacent Text views already start on separate lines. Keep the original
      // separator in raw for exact copying, without drawing an extra blank row.
      let display = index < pieces.count - 1 && raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
      return Chunk(id: index, raw: raw, display: display)
    }
  }
}
