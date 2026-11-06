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
    // Codex shows the command between its question and the options: a block that starts with
    // `$ ` and may continue over more lines, blank ones included. A command approval whose
    // command cannot be read in full never offers its answers.
    if isCommandApproval(lines, above: top, options: options) {
      guard let start = commandStart(lines, endingAt: titleIndex) else { return nil }
      detail = commandText(lines[start...titleIndex])
      var questionIndex = start - 1
      while questionIndex >= 0, isFiller(lines[questionIndex]) { questionIndex -= 1 }
      // A command with no question above it is not a prompt the phone can safely answer.
      guard questionIndex >= 0, start - questionIndex <= 3 else { return nil }
      title = lines[questionIndex].trimmingCharacters(in: .whitespaces)
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

  /// The command in a `$ ` block. Only the terminal's common left margin goes; the script's own
  /// indentation stays, because it can change what the command does (089 review S4-R6).
  private static func commandText(_ block: ArraySlice<String>) -> String {
    let margin =
      block.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
    let text = block.map { $0.count > margin ? String($0.dropFirst(margin)) : "" }.joined(separator: "\n")
    return String(text.dropFirst(2))
  }

  /// How far above the options a command block may start.
  private static let maximumCommandLines = 40

  /// The first line of a `$ command` block that ends at `end`, if the block has one within
  /// `maximumCommandLines`. Blank lines may be part of the script; Codex's `Reason:` line and
  /// question are above the block, so they end the search.
  private static func commandStart(_ lines: [String], endingAt end: Int) -> Int? {
    var index = end
    while index >= 0, end - index < maximumCommandLines {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("$ ") { return index }
      if trimmed.hasPrefix("Reason:") || trimmed.lowercased().hasPrefix("would you like to run") { return nil }
      index -= 1
    }
    return nil
  }

  /// Codex's command approval: its question above the menu, or its options' key hints such as
  /// `(y)` and `(esc)`.
  private static func isCommandApproval(_ lines: [String], above top: Int, options: [Option]) -> Bool {
    let hints = options.contains { $0.label.wholeMatch(of: #/.*\((y|p|a|n|esc)\)/#) != nil }
    let question = lines[max(0, top - maximumCommandLines - 8)..<top].contains {
      $0.lowercased().contains("would you like to run the following command")
    }
    return hints || question
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
