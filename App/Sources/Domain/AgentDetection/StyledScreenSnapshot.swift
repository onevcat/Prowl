import Foundation

/// A VT display snapshot of the active screen split into rows, with the SGR dim attribute
/// kept per Unicode scalar. Agent TUIs render the hint of an empty composer dim, which tells
/// it from an identically worded draft; plain text cannot.
nonisolated struct StyledScreenSnapshot: Sendable {
  nonisolated struct Row: Sendable {
    let text: String
    /// Parallel to `text.unicodeScalars`.
    let dim: [Bool]

    /// True when every scalar from `start` on is whitespace or dim: nothing typed shows there.
    func showsOnlyDimText(from start: Int = 0) -> Bool {
      zip(text.unicodeScalars, dim).dropFirst(start).allSatisfy {
        CharacterSet.whitespaces.contains($0.0) || $0.1
      }
    }
  }

  static let maximumSize = 4 * 1024 * 1024

  let rows: [Row]

  /// The rows without styles, in the shape the screen profiles read.
  var plain: AgentScreenSnapshot {
    AgentScreenSnapshot(text: rows.map(\.text).joined(separator: "\n"))
  }

  /// Nil for an oversized or malformed snapshot. Callers must not read that as an empty screen.
  init?(styledSnapshot: String) {
    guard styledSnapshot.utf8.count <= Self.maximumSize else { return nil }
    let scalars = Array(styledSnapshot.unicodeScalars)
    var index = 0
    var dim = false
    var rows: [(String, [Bool])] = [("", [])]
    while index < scalars.count {
      let scalar = scalars[index]
      if scalar.value == 27 {
        guard let blanks = Self.skipEscape(in: scalars, at: &index, dim: &dim) else { return nil }
        rows[rows.count - 1].0 += String(repeating: " ", count: blanks)
        rows[rows.count - 1].1 += Array(repeating: dim, count: blanks)
        continue
      }
      if scalar.value == 10 {
        rows.append(("", []))
      } else if scalar.value != 13 {
        rows[rows.count - 1].0.unicodeScalars.append(scalar)
        rows[rows.count - 1].1.append(dim)
      }
      index += 1
    }
    self.rows = rows.map { Row(text: $0.0, dim: $0.1) }
  }

  /// Moves `index` past the escape sequence that starts at `scalars[index]` and tracks the SGR
  /// dim attribute. Returns the number of blank cells the sequence stands for: the formatter
  /// encodes a run of cells that were never written as a cursor-forward (CUF) instead of
  /// spaces, and a TUI that positions each word leaves such cells between words. Nil for a
  /// malformed or unterminated sequence.
  private static func skipEscape(in scalars: [Unicode.Scalar], at index: inout Int, dim: inout Bool) -> Int? {
    index += 1
    guard index < scalars.count else { return nil }
    let introducer = scalars[index]
    if introducer == "[" {
      index += 1
      var parameters = ""
      while index < scalars.count, !(64...126).contains(scalars[index].value) {
        parameters.unicodeScalars.append(scalars[index])
        index += 1
      }
      guard index < scalars.count else { return nil }
      if scalars[index] == "m" {
        updateDimAttribute(parameters: parameters, dim: &dim)
      } else if scalars[index] == "C" {
        index += 1
        return max(Int(parameters) ?? 1, 1)
      }
    } else if ["]", "P", "X", "^", "_"].contains(introducer) {
      // OSC (the formatter's palette and default colors), DCS, SOS, PM, and APC strings
      // run to ST or BEL and contain no cells.
      index += 1
      while index < scalars.count, scalars[index].value != 7,
        !(scalars[index].value == 27 && index + 1 < scalars.count && scalars[index + 1] == "\\")
      {
        index += 1
      }
      guard index < scalars.count else { return nil }
      index += scalars[index].value == 7 ? 1 : 2
      return 0
    } else if (0x20...0x2F).contains(introducer.value) {
      // Charset designations and other nF escapes: intermediates, then one final byte.
      while index < scalars.count, (0x20...0x2F).contains(scalars[index].value) { index += 1 }
      guard index < scalars.count, (0x30...0x7E).contains(scalars[index].value) else { return nil }
    } else if !(0x30...0x7E).contains(introducer.value) {
      return nil
    }
    // Two-byte escapes such as DECSC/DECRC, which the formatter emits to restore a pending
    // wrap, or keypad modes contain no cells either.
    index += 1
    return 0
  }

  private static func updateDimAttribute(parameters: String, dim: inout Bool) {
    let codes =
      parameters.isEmpty ? [0] : parameters.split(separator: ";").compactMap { Int($0) }
    var codeIndex = 0
    while codeIndex < codes.count {
      let code = codes[codeIndex]
      if code == 0 || code == 22 { dim = false }
      if code == 2 { dim = true }
      // Color components can equal 0/2/22 but are not standalone SGR attributes.
      if [38, 48, 58].contains(code), codeIndex + 1 < codes.count {
        codeIndex += codes[codeIndex + 1] == 2 ? 4 : 2
      }
      codeIndex += 1
    }
  }
}
