import Foundation

/// Reads the linear display_snapshot export, not arbitrary terminal output. Unknown
/// cursor movement or malformed styling makes the evidence unusable for submission.
nonisolated struct MirrorSnapshotEvidence: Equatable, Sendable {
  struct Style: Equatable, Sendable {
    var bold = false
    var faint = false
    var inverse = false
    var invisible = false
  }

  struct Run: Equatable, Sendable {
    let text: String
    let style: Style
  }

  let lines: [[Run]]
  let cursorRow: Int
  let cursorColumn: Int
  let cursorVisible: Bool
  let bracketedPaste: Bool

  /// Placeholder evidence alone is not permission to submit: the caller must
  /// also validate the Agent generation, runtime state, attachments and edits.
  var codexPlaceholder: String? {
    guard cursorVisible, cursorColumn == 2, lines.indices.contains(cursorRow) else { return nil }
    let runs = lines[cursorRow]
    guard let prompt = runs.first, prompt.text.hasPrefix("›"), prompt.style.bold,
      !prompt.style.faint, !prompt.style.inverse, !prompt.style.invisible,
      runs.map(\.text).joined().hasPrefix("› ")
    else { return nil }
    var prefixRemaining = 2
    var placeholder = ""
    for run in runs {
      let skipped = min(prefixRemaining, run.text.count)
      prefixRemaining -= skipped
      let text = run.text.dropFirst(skipped)
      guard !run.style.invisible, !run.style.inverse else { return nil }
      if !text.trimmingCharacters(in: .whitespaces).isEmpty {
        guard run.style.faint, !run.style.bold else { return nil }
      }
      placeholder += text
    }
    let trimmed = placeholder.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func read(_ frame: MirrorFrame) -> Self? {
    guard frame.bytes.count <= 1_048_576, frame.rows > 0, frame.rows <= 10_000,
      frame.columns > 0, frame.columns <= 10_000
    else { return nil }
    var reader = Reader(bytes: Array(frame.bytes), rows: Int(frame.rows), columns: Int(frame.columns))
    return reader.read()
  }

  private struct Reader {
    let bytes: [UInt8]
    let rows: Int
    let columns: Int
    var index = 0
    var lines: [[Run]] = [[]]
    var style = Style()
    var cursor: (row: Int, column: Int)?
    var cursorVisible = true
    var bracketedPaste = false
    var runCount = 0

    mutating func read() -> MirrorSnapshotEvidence? {
      while index < bytes.count {
        switch bytes[index] {
        case 27:
          guard escape() else { return nil }
        case 13:
          guard cursor == nil, index + 1 < bytes.count, bytes[index + 1] == 10,
            lines.count < rows
          else { return nil }
          lines.append([])
          index += 2
        default:
          guard cursor == nil, appendText() else { return nil }
        }
      }
      guard let cursor else { return nil }
      return MirrorSnapshotEvidence(
        lines: lines, cursorRow: cursor.row, cursorColumn: cursor.column,
        cursorVisible: cursorVisible, bracketedPaste: bracketedPaste)
    }

    mutating func appendText() -> Bool {
      let start = index
      while index < bytes.count, bytes[index] >= 32, bytes[index] != 127 {
        index += 1
      }
      guard index > start, runCount < 32_768,
        let text = String(bytes: bytes[start..<index], encoding: .utf8),
        !text.unicodeScalars.contains(where: { (0x80...0x9F).contains($0.value) })
      else { return false }
      lines[lines.count - 1].append(Run(text: text, style: style))
      runCount += 1
      return true
    }

    mutating func escape() -> Bool {
      guard index + 1 < bytes.count else { return false }
      index += 1
      switch bytes[index] {
      case 93: return osc()
      case 91: return csi()
      default: return false
      }
    }

    mutating func osc() -> Bool {
      index += 1
      let start = index
      while index < bytes.count, index - start <= 8192 {
        if bytes[index] == 27 {
          guard index + 1 < bytes.count, bytes[index + 1] == 92,
            let text = String(bytes: bytes[start..<index], encoding: .utf8),
            let command = text.split(separator: ";", maxSplits: 1).first,
            ["4", "8", "10", "11"].contains(String(command))
          else { return false }
          index += 2
          return true
        }
        guard bytes[index] >= 32, bytes[index] != 127 else { return false }
        index += 1
      }
      return false
    }

    mutating func csi() -> Bool {
      index += 1
      let start = index
      while index < bytes.count, (0x20...0x3F).contains(bytes[index]), index - start < 128 {
        index += 1
      }
      guard index < bytes.count, let parameters = String(bytes: bytes[start..<index], encoding: .utf8) else {
        return false
      }
      let command = bytes[index]
      index += 1
      switch command {
      case 109: return sgr(parameters)
      case 72:
        let fields = parameters.split(separator: ";", omittingEmptySubsequences: false)
        guard cursor == nil, fields.count == 2, let row = Int(fields[0]), let column = Int(fields[1]),
          (1...rows).contains(row), (1...columns).contains(column)
        else { return false }
        cursor = (row - 1, column - 1)
        return true
      case 104, 108:
        guard cursor == nil, runCount == 0, lines.count == 1 else { return false }
        let digits = parameters.hasPrefix("?") ? String(parameters.dropFirst()) : parameters
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        if parameters == "?25" { cursorVisible = command == 104 }
        if parameters == "?2004" { bracketedPaste = command == 104 }
        return true
      default: return false
      }
    }

    mutating func sgr(_ parameters: String) -> Bool {
      let fields = parameters.split(separator: ";", omittingEmptySubsequences: false)
      var position = 0
      while position < fields.count {
        let field = fields[position]
        position += 1
        guard let code = styleCode(field) else { return false }
        switch code {
        case 0: style = Style()
        case 1: style.bold = true
        case 2: style.faint = true
        case 7: style.inverse = true
        case 8: style.invisible = true
        case 22:
          style.bold = false
          style.faint = false
        case 27: style.inverse = false
        case 28: style.invisible = false
        case 38, 48, 58:
          guard consumeColor(fields, position: &position) else { return false }
        case 3...6, 9, 21, 23...26, 29...37, 39...47, 49, 53...55, 59, 90...97, 100...107: break
        default: return false
        }
      }
      return true
    }

    private func consumeColor(_ fields: [Substring], position: inout Int) -> Bool {
      guard position < fields.count, let mode = Int(fields[position]), mode == 2 || mode == 5 else {
        return false
      }
      let count = mode == 2 ? 3 : 1
      position += 1
      guard position + count <= fields.count,
        fields[position..<(position + count)].allSatisfy({ Int($0).map { (0...255).contains($0) } == true })
      else { return false }
      position += count
      return true
    }

    private func styleCode(_ field: Substring) -> Int? {
      if field.hasPrefix("4:") {
        return ["4:0", "4:1", "4:2", "4:3", "4:4", "4:5"].contains(field) ? 4 : nil
      }
      return field.isEmpty ? 0 : Int(field)
    }
  }
}
