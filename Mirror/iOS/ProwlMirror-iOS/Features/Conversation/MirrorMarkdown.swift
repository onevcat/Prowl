import Foundation

/// The block structure of an agent message: headings, lists, quotes, fenced code, tables and
/// rules. Inline syntax (emphasis, code spans, links) stays in the text and is rendered by
/// `AttributedString(markdown:)`. This is a small reader for chat messages, not a full
/// CommonMark implementation.
nonisolated enum MirrorMarkdown {
  enum Block: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([ListItem])
    case quote(String)
    case code(language: String?, text: String)
    case table(header: [String], rows: [[String]])
    case rule
  }

  struct ListItem: Equatable, Sendable {
    enum Marker: Equatable, Sendable {
      case bullet
      case ordered(Int)
      case task(done: Bool)
    }

    var marker: Marker
    var depth: Int
    var text: String
  }

  static func parse(_ text: String) -> [Block] {
    var reader = Reader(lines: text.components(separatedBy: "\n"))
    return reader.blocks()
  }

  struct Fence {
    let character: Character
    let length: Int
    let indent: Int
    let language: String?

    /// A closing fence uses the same character, is at least as long, and has no info string.
    func isClosed(by line: String) -> Bool {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let run = trimmed.prefix { $0 == character }.count
      return run >= length && run == trimmed.count
    }

    func strippingIndent(_ line: String) -> String {
      let spaces = line.prefix { $0 == " " }.count
      return String(line.dropFirst(min(spaces, indent)))
    }
  }

  private struct Reader {
    let lines: [String]
    var index = 0
    var result: [Block] = []
    var paragraph: [String] = []

    init(lines: [String]) { self.lines = lines }

    mutating func blocks() -> [Block] {
      while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
          flushParagraph()
          index += 1
        } else if let fence = Self.fenceOpening(line) {
          flushParagraph()
          readFence(fence)
        } else if let heading = Self.heading(trimmed) {
          flushParagraph()
          result.append(heading)
          index += 1
        } else if Self.isRule(trimmed) {
          flushParagraph()
          result.append(.rule)
          index += 1
        } else if trimmed.hasPrefix(">") {
          flushParagraph()
          readQuote()
        } else if Self.listItem(line) != nil {
          flushParagraph()
          readList()
        } else if trimmed.contains("|"), index + 1 < lines.count,
          Self.isTableDelimiter(lines[index + 1], columns: Self.cells(trimmed).count)
        {
          flushParagraph()
          readTable()
        } else {
          paragraph.append(trimmed)
          index += 1
        }
      }
      flushParagraph()
      return result
    }

    private mutating func flushParagraph() {
      guard !paragraph.isEmpty else { return }
      result.append(.paragraph(paragraph.joined(separator: "\n")))
      paragraph = []
    }

    private mutating func readFence(_ fence: Fence) {
      var body: [String] = []
      index += 1
      while index < lines.count {
        let line = lines[index]
        if fence.isClosed(by: line) {
          index += 1
          break
        }
        body.append(fence.strippingIndent(line))
        index += 1
      }
      result.append(.code(language: fence.language, text: body.joined(separator: "\n")))
    }

    private mutating func readQuote() {
      var body: [String] = []
      while index < lines.count {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { break }
        body.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
        index += 1
      }
      result.append(.quote(body.joined(separator: "\n")))
    }

    private mutating func readList() {
      var items: [ListItem] = []
      while index < lines.count {
        let line = lines[index]
        if let item = Self.listItem(line) {
          items.append(item)
          index += 1
        } else if !items.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty,
          line.hasPrefix("  ") || line.hasPrefix("\t"), Self.fenceOpening(line) == nil
        {
          // A continuation line of the item above.
          items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
          index += 1
        } else {
          break
        }
      }
      result.append(.list(items))
    }

    private mutating func readTable() {
      let header = Self.cells(lines[index])
      index += 2
      var rows: [[String]] = []
      while index < lines.count {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.contains("|") else { break }
        var row = Self.cells(trimmed)
        if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
        rows.append(Array(row.prefix(header.count)))
        index += 1
      }
      result.append(.table(header: header, rows: rows))
    }

    static func heading(_ trimmed: String) -> Block? {
      let hashes = trimmed.prefix { $0 == "#" }.count
      guard (1...6).contains(hashes) else { return nil }
      let rest = trimmed.dropFirst(hashes)
      guard rest.first == " " else { return nil }
      var text = rest.trimmingCharacters(in: .whitespaces)
      // A closing run of `#` counts only after a space: "C#" keeps its hash.
      let closing = text.reversed().prefix { $0 == "#" }.count
      if closing > 0 {
        let body = text.dropLast(closing)
        if body.isEmpty || body.last == " " { text = body.trimmingCharacters(in: .whitespaces) }
      }
      return .heading(level: hashes, text: text)
    }

    /// A fence opens with three or more backticks or tildes; a backtick fence's info string
    /// cannot contain a backtick, so "```make``` then" is inline code.
    static func fenceOpening(_ line: String) -> Fence? {
      // No depth limit: a fence nested in a list sits as deep as its item.
      let indent = line.prefix { $0 == " " }.count
      let trimmed = line.dropFirst(indent)
      guard let character = trimmed.first, character == "`" || character == "~" else { return nil }
      let length = trimmed.prefix { $0 == character }.count
      guard length >= 3 else { return nil }
      let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
      if character == "`", info.contains("`") { return nil }
      return Fence(character: character, length: length, indent: indent, language: info.isEmpty ? nil : info)
    }

    static func isRule(_ trimmed: String) -> Bool {
      let compact = trimmed.filter { $0 != " " }
      guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
      return compact.allSatisfy { $0 == first }
    }

    static func listItem(_ line: String) -> ListItem? {
      let indent = line.prefix { $0 == " " || $0 == "\t" }
      let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
      let body = line.dropFirst(indent.count)
      var marker: ListItem.Marker
      var rest: Substring
      if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
        marker = .bullet
        rest = body.dropFirst(2)
      } else {
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
        let after = body.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")", after.dropFirst().first == " "
        else { return nil }
        marker = .ordered(number)
        rest = after.dropFirst(2)
      }
      if marker == .bullet, rest.hasPrefix("[ ] ") || rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
        marker = .task(done: rest.dropFirst().first != " ")
        rest = rest.dropFirst(4)
      }
      return ListItem(marker: marker, depth: width / 2, text: rest.trimmingCharacters(in: .whitespaces))
    }

    static func isTableDelimiter(_ line: String, columns: Int) -> Bool {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.contains("-"), trimmed.contains("|") else { return false }
      let delimiters = cells(trimmed)
      return delimiters.count == columns
        && delimiters.allSatisfy { cell in
          !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
        }
    }

    /// The cells of a table row; `\|` is a literal pipe.
    static func cells(_ line: String) -> [String] {
      var trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("|") { trimmed.removeFirst() }
      if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
      var cells: [String] = []
      var current = ""
      var escaped = false
      for character in trimmed {
        if escaped {
          if character != "|" { current.append("\\") }
          current.append(character)
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "|" {
          cells.append(current.trimmingCharacters(in: .whitespaces))
          current = ""
        } else {
          current.append(character)
        }
      }
      if escaped { current.append("\\") }
      cells.append(current.trimmingCharacters(in: .whitespaces))
      return cells
    }
  }
}

/// Text that Prowl adds to a launch prompt, such as the dispatch completion protocol. The
/// transcript keeps it as part of the user message; the chat shows it folded.
nonisolated enum MirrorInjectedText {
  /// The separator `AgentProfileLaunchPlan` puts between the prompt and the protocol.
  private static let marker = "\n\n---\nProwl dispatch completion protocol v"

  private static let separator = "\n\n---\n"
  /// The shortest tail that still names Prowl, for a message the Host cut inside the marker.
  private static let minimumPartial = separator.count + "Prowl".count

  static func split(_ text: String) -> (message: String, injected: String?) {
    let start: String.Index
    if let range = text.range(of: marker) {
      start = range.lowerBound
    } else if let partial = partialMarker(in: text) {
      start = partial
    } else {
      return (text, nil)
    }
    let message = String(text[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
    let injectedStart = text.index(start, offsetBy: separator.count)
    return (message, String(text[injectedStart...]))
  }

  private static func partialMarker(in text: String) -> String.Index? {
    guard let range = text.range(of: separator, options: .backwards) else { return nil }
    let tail = text[range.lowerBound...]
    guard tail.count >= minimumPartial, marker.hasPrefix(tail) else { return nil }
    return range.lowerBound
  }
}
