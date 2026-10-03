import Foundation

nonisolated struct MirrorDocument {
  enum Block: Equatable, Identifiable {
    case text(Int, String)
    case code(Int, String, String)
    case table(Int, String, [[String]])

    var id: Int {
      switch self {
      case .text(let id, _), .code(let id, _, _), .table(let id, _, _): id
      }
    }
    var raw: String {
      switch self {
      case .text(_, let text), .table(_, let text, _): text
      case .code(_, _, let code): code
      }
    }
  }

  let blocks: [Block]

  init(_ text: String) {
    let lines = text.components(separatedBy: "\n")
    var result: [Block] = []
    var pending: [String] = []
    var index = 0
    func flush() {
      guard !pending.isEmpty else { return }
      result.append(.text(result.count, pending.joined(separator: "\n")))
      pending = []
    }
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        flush()
        let language = String(trimmed.dropFirst(3))
        index += 1
        var code: [String] = []
        while index < lines.count,
          !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```")
        {
          code.append(lines[index])
          index += 1
        }
        result.append(.code(result.count, language, code.joined(separator: "\n")))
        if index < lines.count { index += 1 }
      } else if index + 1 < lines.count, let header = Self.cells(line),
        let separator = Self.cells(lines[index + 1]), separator.count == header.count,
        separator.allSatisfy({ cell in
          let marks = cell.replacing(":", with: "")
          return marks.count >= 3 && marks.allSatisfy { $0 == "-" }
        })
      {
        flush()
        var rows = [header]
        var raw = [line, lines[index + 1]]
        index += 2
        while index < lines.count, let cells = Self.cells(lines[index]), cells.count == header.count
        {
          rows.append(cells)
          raw.append(lines[index])
          index += 1
        }
        result.append(.table(result.count, raw.joined(separator: "\n"), rows))
      } else {
        pending.append(line)
        index += 1
      }
    }
    flush()
    blocks = result
  }

  private static func cells(_ line: String) -> [String]? {
    let line = line.trimmingCharacters(in: .whitespaces)
    guard line.hasPrefix("|"), line.hasSuffix("|"), !line.contains("\\|") else { return nil }
    let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    return cells.count > 1 ? cells : nil
  }
}
