import Foundation

/// A choice menu an agent shows at the bottom of its screen while it waits for a person
/// (docs-ai 089 S4): Claude Code's permission and AskUserQuestion dialogs, Codex's approval, and
/// the folder trust dialog both show before the first turn in a new folder.
/// Parsed from the visible text only, so it works for any launch and needs no hook content.
/// The phone answers through it, and the Host re-reads the screen before every key.
nonisolated struct MirrorScreenPrompt: Equatable, Sendable {
  struct Option: Equatable, Sendable {
    let number: Int
    let label: String
    var detail: String?
    /// "Type something." / "Chat about this": rows that open a text field or a chat, not answers.
    var isFreeform: Bool
    /// The box of a multi-select row (`[ ]` or `[✔]`); nil in a single-select menu.
    var checked: Bool?
  }

  /// A row the highlight can sit on: a numbered option, or the Submit row of a multi-select
  /// menu, which has no number.
  enum Target: Hashable, Sendable {
    case option(Int)
    case submit
  }

  let title: String
  /// Lines quoted above the question, such as the command a permission asks about, or the
  /// answers a review page is about to submit.
  let detail: String?
  let options: [Option]
  /// Every row the highlight can reach, in screen order.
  let rows: [Target]
  let highlighted: Target

  /// The menu's content identity: everything a person decides on (question, the command or
  /// other detail, every answer and its description), but not the highlight, the boxes or the
  /// text typed into a freeform row, which change while the same menu stays open. Two
  /// permissions that differ only in their command are different prompts. The feed adds an
  /// occurrence, so the same menu shown twice still gets two wire ids.
  var id: String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    let parts =
      [title, detail ?? "", isMultiSelect ? "multi" : "single"] + answers.flatMap { [$0.label, $0.detail ?? ""] }
    for byte in parts.joined(separator: "\u{1F}").utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01B3
    }
    return "screen:" + String(hash, radix: 16)
  }

  /// What may change while the menu keeps its identity and the phone must still see: the boxes.
  var state: [Bool?] { answers.map(\.checked) }

  var isMultiSelect: Bool { options.contains { $0.checked != nil } }

  var isPermission: Bool {
    let lower = title.lowercased()
    return lower.contains("do you want to proceed") || lower.contains("would you like to run")
      || lower.contains("allow") || lower.contains("approve")
  }

  /// The one key that moves the highlight a row toward `target`, or confirms it there; nil when
  /// the menu has no such row. The Host re-reads the screen after every key, so a menu that
  /// changed stops the answer.
  func nextKey(toward target: Target) -> String? {
    guard let current = rows.firstIndex(of: highlighted), let goal = rows.firstIndex(of: target) else { return nil }
    if current < goal { return "down" }
    if current > goal { return "up" }
    return "enter"
  }

  /// The row the highlight reaches after `key` moves it one row.
  func target(after key: String) -> Target? {
    guard let index = rows.firstIndex(of: highlighted) else { return nil }
    let next = key == "down" ? index + 1 : key == "up" ? index - 1 : index
    return rows.indices.contains(next) ? rows[next] : nil
  }

  /// The answers a person can pick from the phone.
  var answers: [Option] { options.filter { !$0.isFreeform } }

  /// Option rows: `❯ 1. Yes`, `  2. No`, Codex's `› 1. Yes, proceed (y)`. `Regex` is not
  /// Sendable; this literal is immutable and only read.
  nonisolated(unsafe) private static let optionPattern =
    #/^\s*(?<marker>[❯›>])?\s*(?<number>\d{1,2})\.\s+(?:\[(?<box>[ ✔✓xX×])\]\s+)?(?<label>\S.*?)\s*$/#
  /// The unnumbered Submit row under the options of a multi-select menu.
  nonisolated(unsafe) private static let submitPattern = #/^\s*(?<marker>[❯›>])?\s*Submit\s*$/#
  /// Questions that end a dialog without a footer line: Claude Code's review page.
  private static let footerlessTitles: Set<String> = ["ready to submit your answers?"]
  /// A footer that only a choice dialog shows; it keeps numbered lists in prose from parsing.
  private static let footerMarkers = [
    "enter to select", "enter to confirm", "esc to cancel", "to navigate", "press enter",
  ]

  static func parse(_ text: String) -> MirrorScreenPrompt? {
    let lines = text.components(separatedBy: "\n").map { line in
      String(line.reversed().drop { $0 == " " }.reversed())
    }
    if let trust = folderTrust(lines) { return trust }
    guard let (footer, footerless) = menuEnd(lines) else { return nil }

    // Walk up from the footer through option rows, their descriptions, blanks and rules.
    var top: Int?
    var index = footer - 1
    while index >= 0 {
      let line = lines[index]
      if line.wholeMatch(of: optionPattern) != nil {
        top = index
      } else if isFiller(line) || isIndented(line) || line.wholeMatch(of: submitPattern) != nil {
        // Fillers, descriptions and the Submit row belong to the menu; keep walking.
      } else {
        break
      }
      index -= 1
    }
    guard let top else { return nil }

    let menu = readOptions(lines[top..<footer])
    guard let highlighted = menu.highlighted, !menu.options.isEmpty,
      menu.options.map(\.number) == Array(1...menu.options.count)
    else { return nil }

    guard let question = question(lines, above: top) else { return nil }
    var title = question.title
    let titleIndex = question.lines.upperBound
    let titleStart = question.lines.lowerBound
    if footerless {
      guard footerlessTitles.contains(title.lowercased()) else { return nil }
    }
    var detail = footerless ? reviewSummary(lines, above: titleStart) : quotedDetail(lines, above: titleStart)
    // Codex shows the command between its question and the options: a block that starts with
    // `$ ` and may continue over more lines, blank ones included. A command approval whose
    // command cannot be read in full never offers its answers.
    if isCommandApproval(lines, above: top, options: menu.options) {
      guard let start = commandStart(lines, endingAt: titleIndex) else { return nil }
      detail = commandText(lines[start...titleIndex])
      var questionIndex = start - 1
      while questionIndex >= 0, isFiller(lines[questionIndex]) { questionIndex -= 1 }
      // A command with no question above it is not a prompt the phone can safely answer.
      guard questionIndex >= 0, start - questionIndex <= 3 else { return nil }
      title = lines[questionIndex].trimmingCharacters(in: .whitespaces)
    }
    return MirrorScreenPrompt(
      title: title, detail: detail, options: menu.options, rows: menu.rows, highlighted: highlighted)
  }

  /// The dialog's heading, then the footer of its menu, per agent.
  private static let folderTrustDialogs = [
    (heading: "accessing workspace:", footer: "enter to confirm"),
    (heading: "folder access", footer: "enter continue"),
  ]
  /// An unnumbered menu row, as in Claude Code's folder trust dialog.
  nonisolated(unsafe) private static let plainRowPattern = #/^\s*(?<marker>[❯›>])?\s*(?<label>\S.*?)\s*$/#

  /// The folder trust dialog Claude Code and Codex show before the first turn in a new folder.
  /// It is the whole screen, so it is known by its heading, the folder under the heading and
  /// its footer; its rows may have no numbers (Claude Code) and then get their screen order.
  /// A dialog that does not show the folder, a row that names trust and one highlighted row
  /// offers no answers.
  private static func folderTrust(_ lines: [String]) -> MirrorScreenPrompt? {
    func text(_ index: Int) -> String { lines[index].trimmingCharacters(in: .whitespaces) }
    guard let last = lines.indices.last(where: { !text($0).isEmpty }) else { return nil }
    for dialog in folderTrustDialogs {
      guard text(last).lowercased().hasPrefix(dialog.footer),
        let heading = lines[...last].lastIndex(where: {
          $0.trimmingCharacters(in: .whitespaces).lowercased() == dialog.heading
        }),
        let folder = lines[(heading + 1)..<last].first(where: {
          !$0.trimmingCharacters(in: .whitespaces).isEmpty
        })?.trimmingCharacters(in: .whitespaces), folder.hasPrefix("/")
      else { continue }
      // The rows: the block of lines directly above the footer.
      var bottom = last - 1
      while bottom > heading, text(bottom).isEmpty { bottom -= 1 }
      var top = bottom
      while top - 1 > heading, !text(top - 1).isEmpty, bottom - top < 3 { top -= 1 }
      var region = Array(lines[top...bottom])
      let numbered = region.filter { $0.wholeMatch(of: optionPattern) != nil }
      if numbered.isEmpty {
        // Number the rows so they read like every other menu.
        region = region.enumerated().compactMap { offset, line in
          guard let match = line.wholeMatch(of: plainRowPattern) else { return nil }
          return "\(match.marker.map(String.init) ?? " ") \(offset + 1). \(match.label)"
        }
      } else {
        // Codex puts its question directly above the rows; only the rows count.
        region = numbered
      }
      let menu = readOptions(region[...])
      guard let highlighted = menu.highlighted, (2...4).contains(menu.options.count),
        menu.options.map(\.number) == Array(1...menu.options.count),
        region.filter({ $0.wholeMatch(of: optionPattern)?.marker != nil }).count == 1,
        menu.options.contains(where: { $0.label.lowercased().contains("trust") })
      else { return nil }
      let options = menu.options.map { Option(number: $0.number, label: $0.label, detail: nil, isFreeform: false) }
      return MirrorScreenPrompt(
        title: "Trust this folder?", detail: folder, options: options, rows: menu.rows, highlighted: highlighted)
    }
    return nil
  }

  /// Where the menu ends: at its footer near the bottom of the screen, or, for Claude's review
  /// page, which has none, after its last row. `footerless` menus need a known question.
  private static func menuEnd(_ lines: [String]) -> (footer: Int, footerless: Bool)? {
    if let footer = lines.indices.reversed().prefix(12).first(where: { index in
      let lower = lines[index].lowercased()
      return footerMarkers.contains { lower.contains($0) }
    }) {
      return (footer, false)
    }
    guard let last = lines.indices.last(where: { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }),
      lines[last].wholeMatch(of: optionPattern) != nil
    else { return nil }
    return (last + 1, true)
  }

  /// The question above the options: the nearest prose line. A multi-question dialog quotes it
  /// with `│`, over as many lines as it wraps; those lines become one title.
  private static func question(_ lines: [String], above top: Int) -> (title: String, lines: ClosedRange<Int>)? {
    var end = top - 1
    while end >= 0, isFiller(lines[end]) { end -= 1 }
    guard end >= 0 else { return nil }
    let title = lines[end].trimmingCharacters(in: .whitespaces)
    guard title.wholeMatch(of: optionPattern) == nil else { return nil }
    guard title.hasPrefix("│") else { return (title, end...end) }
    var start = end
    while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("│") { start -= 1 }
    return (lines[start...end].map(unquoted).joined(separator: " "), start...end)
  }

  private struct Menu {
    var options: [Option] = []
    /// Every row the highlight can reach, in screen order.
    var rows: [Target] = []
    var highlighted: Target?
  }

  /// The option rows of a menu region, their descriptions, every row the highlight can reach,
  /// and the highlighted one.
  private static func readOptions(_ region: ArraySlice<String>) -> Menu {
    var menu = Menu()
    var afterRule = false
    for line in region {
      if let match = line.wholeMatch(of: submitPattern), !menu.options.isEmpty {
        menu.rows.append(.submit)
        if match.marker != nil { menu.highlighted = .submit }
      } else if let match = line.wholeMatch(of: optionPattern), let number = Int(match.number) {
        let label = String(match.label)
        let lower = label.lowercased()
        let opensChat = lower.hasPrefix("chat about this")
        menu.options.append(
          Option(
            number: number, label: label, detail: nil,
            isFreeform: lower.hasPrefix("type something") || opensChat,
            checked: match.box.map { $0 != " " }))
        menu.rows.append(.option(number))
        if match.marker != nil { menu.highlighted = .option(number) }
        // Claude's "Type something" row shows what the person types instead of its hint, so it
        // is known by its place: the last option above the rule before "Chat about this".
        if opensChat, afterRule, let index = menu.options.firstIndex(where: { $0.number == number - 1 }) {
          menu.options[index].isFreeform = true
        }
      } else if isRule(line), !menu.options.isEmpty {
        afterRule = true
      } else if isIndented(line), case .option = menu.rows.last {
        let detail = line.trimmingCharacters(in: .whitespaces)
        menu.options[menu.options.count - 1].detail = [menu.options[menu.options.count - 1].detail, detail].compactMap {
          $0
        }
        .joined(separator: " ")
      }
    }
    return menu
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

  /// Claude shows the command under review a few rows above the question, between dashed
  /// rules: in `│ …` lines, or as plain lines (2.1.322 does both). A `│ …` block under the
  /// last rule says why the command needs approval. All blocks are the detail, the command
  /// first; the note alone must never stand for the command.
  private static func quotedDetail(_ lines: [String], above index: Int) -> String? {
    var blocks: [String] = []
    var quoted: [String] = []
    var belowRule = false
    func closeQuoted() {
      if !quoted.isEmpty { blocks.insert(quoted.joined(separator: " "), at: 0) }
      quoted = []
    }
    var cursor = index - 1
    while cursor >= 0, index - cursor <= maximumQuotedLines {
      let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
      // The dialog's solid top border: anything above it is the conversation, not the dialog.
      if isBorder(trimmed) { break }
      if trimmed.hasPrefix("│") {
        quoted.insert(trimmed.dropFirst().trimmingCharacters(in: .whitespaces), at: 0)
        belowRule = false
      } else if isRule(trimmed) {
        closeQuoted()
        belowRule = true
      } else if belowRule, !trimmed.isEmpty, let top = ruleAbove(lines, from: cursor) {
        // Plain lines between two dashed rules: the command, line by line.
        blocks.insert(
          lines[(top + 1)...cursor].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"), at: 0)
        cursor = top
        continue
      } else if !quoted.isEmpty || !blocks.isEmpty {
        break
      }
      cursor -= 1
    }
    closeQuoted()
    return blocks.isEmpty ? nil : blocks.joined(separator: "\n")
  }

  /// The dashed rule that opens the block whose last line is `index`, if it is within reach
  /// and inside the dialog. A script may hold blank lines.
  private static func ruleAbove(_ lines: [String], from index: Int) -> Int? {
    var cursor = index - 1
    while cursor >= 0, index - cursor <= maximumCommandLines {
      let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
      if isBorder(trimmed) || trimmed.hasPrefix("│") { return nil }
      if isRule(trimmed) { return cursor }
      cursor -= 1
    }
    return nil
  }

  /// How far above the question the quoted blocks may reach.
  private static let maximumQuotedLines = 24

  /// The answers a review page is about to submit: the lines between "Review your answers"
  /// and its question, without the `│` and `●` markers.
  private static func reviewSummary(_ lines: [String], above index: Int) -> String? {
    guard
      let heading = lines[max(0, index - 40)..<index].lastIndex(where: {
        $0.trimmingCharacters(in: .whitespaces).lowercased() == "review your answers"
      })
    else { return nil }
    let summary = lines[(heading + 1)..<index].map(unquoted).map { line in
      line.hasPrefix("● ") ? String(line.dropFirst(2)) : line
    }
    .filter { !$0.isEmpty }
    return summary.isEmpty ? nil : summary.joined(separator: "\n")
  }

  /// A line without its `│` quote marker and the spaces around it.
  private static func unquoted(_ line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("│") ? trimmed.dropFirst().trimmingCharacters(in: .whitespaces) : trimmed
  }

  private static func isBorder(_ trimmed: String) -> Bool {
    trimmed.count >= 3 && trimmed.allSatisfy { "─━".contains($0) }
  }

  private static func isRule(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.count >= 3 && trimmed.allSatisfy { "─━╌╍-═".contains($0) }
  }

  private static func isIndented(_ line: String) -> Bool {
    line.hasPrefix("     ") && !line.trimmingCharacters(in: .whitespaces).isEmpty
  }
}
