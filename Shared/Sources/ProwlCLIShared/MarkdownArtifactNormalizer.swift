// ProwlShared/MarkdownArtifactNormalizer.swift
// Strips the chat wrapping agents put around a markdown document (an opening fence, preamble
// before the first heading, the closing fence and any trailer after it). Shared by the handoff
// briefing validation and the workflow delivery validation so both accept the same replies.

import Foundation

nonisolated public enum MarkdownArtifactNormalizer {
  /// The document without chat wrapping, trimmed; empty when nothing remains. Prowl never
  /// authors prose here: only wrapping is removed, the document body is kept verbatim.
  public static func normalized(_ text: String) -> String {
    var text = droppingPreambleBeforeOpeningFence(text.trimmingCharacters(in: .whitespacesAndNewlines))
    let openingFence = fence(opening: text.firstLine)
    text = droppingOpeningFence(text)
    text = droppingPreamble(text)
    text = droppingClosingFence(text, openingFence: openingFence)
    return text
  }

  /// ATX heading lines outside fenced code blocks, trimmed (`## Findings (2)`). A heading
  /// quoted inside a fence — or indented four spaces, which is code — is not structure and
  /// never satisfies a required section.
  public static func headings(outsideFences text: String) -> [String] {
    var headings: [String] = []
    var open: Fence?
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if let fence = open {
        if closes(line.trimmingCharacters(in: .whitespaces), fence) { open = nil }
        continue
      }
      if let fence = fence(opening: line.trimmingCharacters(in: .whitespaces)) {
        open = fence
        continue
      }
      if let heading = atxHeading(line) {
        headings.append(heading)
      }
    }
    return headings
  }

  /// Whether every required section is present as a heading line outside fences. Matching is
  /// forgiving about what does not change meaning: the heading level (`##` vs `###`), letter
  /// case, and trailing text after a space (`## Findings (2)`).
  public static func hasSections(_ sections: [String], in text: String) -> Bool {
    missingSections(sections, in: text).isEmpty
  }

  /// The required sections that no heading outside a fence satisfies, in declaration order.
  public static func missingSections(_ sections: [String], in text: String) -> [String] {
    let headings = headings(outsideFences: text).map(headingKey)
    return sections.filter { section in
      let wanted = headingKey(section)
      return !headings.contains { $0 == wanted || $0.hasPrefix(wanted + " ") }
    }
  }

  private static func headingKey(_ heading: String) -> String {
    heading.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
  }

  /// The heading text of a CommonMark ATX heading line: up to three spaces of indentation,
  /// one to six `#`, then a space or the end of the line. Four spaces of indentation is code.
  static func atxHeading(_ line: String) -> String? {
    let indentation = line.prefix { $0 == " " }.count
    guard indentation <= 3 else { return nil }
    let body = line.dropFirst(indentation)
    let hashes = body.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let rest = body.dropFirst(hashes)
    guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
    return body.trimmingCharacters(in: .whitespaces)
  }

  /// A fenced-code delimiter: the fence character and the length of its run (CommonMark: at
  /// least three backticks or tildes; the closer uses the same character, at least as long,
  /// and carries nothing but whitespace after the run).
  private struct Fence: Equatable {
    let character: Character
    let length: Int
    /// The line carried an info string (```` ```swift ````); a bare run has none.
    let hasInfoString: Bool
  }

  private static func fence(opening line: String) -> Fence? {
    guard let first = line.first, first == "`" || first == "~" else { return nil }
    let length = line.prefix { $0 == first }.count
    guard length >= 3 else { return nil }
    let info = line.dropFirst(length)
    return Fence(character: first, length: length, hasInfoString: !info.allSatisfy(\.isWhitespace))
  }

  private static func closes(_ line: String, _ fence: Fence) -> Bool {
    let run = line.prefix { $0 == fence.character }
    guard run.count >= fence.length else { return false }
    return line.dropFirst(run.count).allSatisfy(\.isWhitespace)
  }

  /// A line that is nothing but a fence run (any length ≥ 3, backticks or tildes).
  private static func isBareFence(_ line: String) -> Bool {
    guard let fence = fence(opening: line) else { return false }
    return closes(line, fence)
  }

  private static func isHeading(_ line: Substring) -> Bool {
    atxHeading(String(line)) != nil
  }

  /// A reply may put chatter *before* the fence that wraps the document ("Sure, here it is:"
  /// then "```markdown"). When a fence line precedes the first heading, everything up to that
  /// fence is preamble and the fence becomes the opening fence.
  private static func droppingPreambleBeforeOpeningFence(_ text: String) -> String {
    guard fence(opening: text.firstLine) == nil, !isHeading(Substring(text.firstLine)) else { return text }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let heading = lines.firstIndex(where: isHeading),
      let fenceIndex = lines.firstIndex(where: { fence(opening: String($0)) != nil }), fenceIndex < heading
    else { return text }
    return lines[fenceIndex...].joined(separator: "\n")
  }

  /// Unwraps the opening line of a markdown code fence ("```markdown" / "~~~markdown").
  private static func droppingOpeningFence(_ text: String) -> String {
    guard fence(opening: text.firstLine) != nil else { return text }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Drops chat preamble ahead of the document ("Sure, here's the file: …").
  private static func droppingPreamble(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let first = lines.first, !isHeading(first) else { return text }
    guard let start = lines.firstIndex(where: isHeading) else { return text }
    return lines[start...].joined(separator: "\n")
  }

  /// Drops the wrapper's closing fence and the chatter after it. With an opening wrapper fence
  /// the candidates are the bare runs that match it while no inner block opened with an info
  /// string (```` ```swift ````) is still open. Agents also embed *bare* code blocks, so the cut
  /// is the last candidate — unless a block with an info string opens after a candidate, which
  /// is a code block in the trailer: then the last candidate before it closes the wrapper.
  /// Without an opening fence only an exact trailing bare fence line is removed, so a fence
  /// inside a document body is never a cut point.
  private static func droppingClosingFence(_ text: String, openingFence: Fence?) -> String {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let openingFence else {
      if let last = lines.last, isBareFence(last.trimmingCharacters(in: .whitespaces)) {
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      }
      return text
    }
    var depth = 0
    var candidates: [Int] = []
    var trailerStart: Int?
    for (index, rawLine) in lines.enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if closes(line, openingFence) {
        if depth == 0 {
          candidates.append(index)
        } else {
          depth -= 1
        }
      } else if let inner = fence(opening: line) {
        if inner.hasInfoString {
          if depth == 0, !candidates.isEmpty, trailerStart == nil {
            trailerStart = index
          }
          depth += 1
        } else if depth > 0 {
          depth -= 1
        }
      }
    }
    let cut = trailerStart.map { start in candidates.last { $0 < start } } ?? candidates.last
    guard let cut else { return text }
    return lines[..<cut].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

nonisolated extension String {
  fileprivate var firstLine: String {
    String(prefix { $0 != "\n" })
  }
}
