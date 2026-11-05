import Foundation

/// A choice menu an agent shows at the bottom of its screen while it waits for a person
/// (docs-ai 089 S4): Claude Code's permission and AskUserQuestion dialogs, Codex's approval.
/// Parsed from the visible text only, so it works for any launch and needs no hook content.
/// The phone answers through it, and the Host re-reads the screen before every key.
nonisolated struct MirrorScreenPrompt: Equatable, Sendable {
  struct Option: Equatable, Sendable {
    let number: Int
    let label: String
    var detail: String?
    /// "Type something." / "Chat about this": rows that open a text field or a chat, not answers.
    let isFreeform: Bool
  }

  let title: String
  /// Lines quoted above the question, such as the command a permission asks about.
  let detail: String?
  let options: [Option]
  /// The 1-based number of the highlighted option.
  let selected: Int

  /// The menu's content identity: everything a person decides on (question, the command or
  /// other detail, every option and its description), but not the highlight. Two permissions
  /// that differ only in their command are different prompts. The feed adds an occurrence, so
  /// the same menu shown twice still gets two wire ids.
  var id: String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    let parts = [title, detail ?? ""] + options.flatMap { [$0.label, $0.detail ?? ""] }
    for byte in parts.joined(separator: "\u{1F}").utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01B3
    }
    return "screen:" + String(hash, radix: 16)
  }

  var isPermission: Bool {
    let lower = title.lowercased()
    return lower.contains("do you want to proceed") || lower.contains("would you like to run")
      || lower.contains("allow") || lower.contains("approve")
  }

  /// The one key that moves the highlight a row toward `target`, or confirms it there. The
  /// Host re-reads the screen after every key, so a menu that changed stops the answer.
  static func nextKey(selected: Int, target: Int) -> String {
    if selected < target { return "down" }
    if selected > target { return "up" }
    return "enter"
  }

  /// The answers a person can pick from the phone.
  var answers: [Option] { options.filter { !$0.isFreeform } }

  /// Option rows: `❯ 1. Yes`, `  2. No`, Codex's `› 1. Yes, proceed (y)`. `Regex` is not
  /// Sendable; this literal is immutable and only read.
  nonisolated(unsafe) private static let optionPattern =
    #/^\s*(?<marker>[❯›>])?\s*(?<number>\d{1,2})\.\s+(?<label>\S.*?)\s*$/#
  /// A footer that only a choice dialog shows; it keeps numbered lists in prose from parsing.
  private static let footerMarkers = [
    "enter to select", "enter to confirm", "esc to cancel", "to navigate", "press enter",
  ]

  static func parse(_ text: String) -> MirrorScreenPrompt? {
    let lines = text.components(separatedBy: "\n").map { line in
      String(line.reversed().drop { $0 == " " }.reversed())
    }
    // The dialog ends with its footer, near the bottom of the screen.
    guard
      let footer = lines.indices.reversed().prefix(12).first(where: { index in
        let lower = lines[index].lowercased()
        return footerMarkers.contains { lower.contains($0) }
      })
    else { return nil }

    // Walk up from the footer through option rows, their descriptions, blanks and rules.
    var top: Int?
    var index = footer - 1
    while index >= 0 {
      let line = lines[index]
      if line.wholeMatch(of: optionPattern) != nil {
        top = index
      } else if isFiller(line) || (top != nil && isIndented(line)) || (top == nil && isIndented(line)) {
        // Fillers and descriptions belong to the menu; keep walking.
      } else {
        break
      }
      index -= 1
    }
    guard let top else { return nil }

    let (options, selected) = readOptions(lines[top..<footer])
    guard let selected, !options.isEmpty, options.map(\.number) == Array(1...options.count) else { return nil }

    // The title: the nearest prose line above the options.
    var titleIndex = top - 1
    while titleIndex >= 0, isFiller(lines[titleIndex]) { titleIndex -= 1 }
    guard titleIndex >= 0 else { return nil }
    var title = lines[titleIndex].trimmingCharacters(in: .whitespaces)
    guard title.wholeMatch(of: optionPattern) == nil else { return nil }
    var detail = quotedDetail(lines, above: titleIndex)
    // Codex shows the command () between its question and the options.
    if title.hasPrefix("$ ") {
      detail = String(title.dropFirst(2))
      var questionIndex = titleIndex - 1
      while questionIndex >= 0, isFiller(lines[questionIndex]) { questionIndex -= 1 }
      if questionIndex >= 0, titleIndex - questionIndex <= 3 {
        title = lines[questionIndex].trimmingCharacters(in: .whitespaces)
      }
    }
    return MirrorScreenPrompt(title: title, detail: detail, options: options, selected: selected)
  }

  /// The option rows of a menu region, their descriptions, and the highlighted number.
  private static func readOptions(_ region: ArraySlice<String>) -> (options: [Option], selected: Int?) {
    var options: [Option] = []
    var selected: Int?
    for line in region {
      if let match = line.wholeMatch(of: optionPattern), let number = Int(match.number) {
        let label = String(match.label)
        let lower = label.lowercased()
        options.append(
          Option(
            number: number, label: label, detail: nil,
            isFreeform: lower.hasPrefix("type something") || lower.hasPrefix("chat about this")))
        if match.marker != nil { selected = number }
      } else if isIndented(line), !options.isEmpty {
        let detail = line.trimmingCharacters(in: .whitespaces)
        options[options.count - 1].detail = [options[options.count - 1].detail, detail].compactMap { $0 }
          .joined(separator: " ")
      }
    }
    return (options, selected)
  }

  private static func isFiller(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces).isEmpty || isRule(line)
  }

  /// Claude quotes the command under review in `│ …` lines a few rows above the question.
  private static func quotedDetail(_ lines: [String], above index: Int) -> String? {
    var quoted: [String] = []
    var cursor = index - 1
    while cursor >= 0, index - cursor <= 14 {
      let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("│") {
        quoted.insert(trimmed.dropFirst().trimmingCharacters(in: .whitespaces), at: 0)
      } else if !quoted.isEmpty {
        break
      }
      cursor -= 1
    }
    return quoted.isEmpty ? nil : quoted.joined(separator: " ")
  }

  private static func isRule(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.count >= 3 && trimmed.allSatisfy { "─━╌╍-═".contains($0) }
  }

  private static func isIndented(_ line: String) -> Bool {
    line.hasPrefix("     ") && !line.trimmingCharacters(in: .whitespaces).isEmpty
  }
}
