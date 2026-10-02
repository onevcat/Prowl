import Foundation
import Testing

@testable import supacode

/// `normalize` runs an ASCII byte-scan fast path in place of the Swift Regex +
/// grapheme-split reference. It must be indistinguishable from that reference
/// for every input, or fingerprint matching would silently change which
/// transcript wins.
struct AgentSessionFingerprintNormalizeTests {
  /// Inputs chosen to exercise every branch of the fast path and every reason it
  /// bails out to the general path.
  private static let corpus: [String] = [
    "",
    " ",
    "\t\n \r\n",
    "plain text",
    "  leading and trailing  ",
    "MiXeD CaSe TEXT",
    "collapse\t\tmultiple\n\nwhitespace\u{000B}runs\u{000C}here",
    "windows\r\nline\r\nendings",
    // ANSI: reset, params, private-mode param byte, an intermediate byte.
    "\u{001B}[0mreset",
    "\u{001B}[1;31mred\u{001B}[0m normal",
    "\u{001B}[?25hcursor shown",
    "\u{001B}[ qbar cursor",
    "adjacent\u{001B}[0m\u{001B}[1msequences",
    "\u{001B}[2Jleading sequence",
    "trailing sequence\u{001B}[0m",
    // Malformed: these must survive as ordinary text, not be swallowed.
    "bare \u{001B} escape",
    "truncated \u{001B}[",
    "no final byte \u{001B}[1;2",
    "escape at end \u{001B}",
    "\u{001B}",
    "\u{001B}[",
    // Non-ASCII must defer to the general path.
    "héllo wörld",
    "CAFÉ AU LAIT",
    "日本語のテキストです",
    "emoji 🎉 mixed with ascii",
    "non-breaking\u{00A0}space",
    "next\u{0085}line",
    "İstanbul uppercase dotted i",
    "ﬁ ligature",
    "\u{001B}[31mré\u{001B}[0m d",
    "mixed ascii and ünicode with  spacing",
  ]

  /// The original formulation, before either the ASCII fast path or the
  /// escape-absence guard. Both shipped paths must reproduce it exactly.
  private static func pristine(_ value: String) -> String {
    value
      .replacing(#/\u{001B}\[[0-?]*[ -\/]*[@-~]/#, with: " ")
      .lowercased()
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
  }

  @Test func bothPathsMatchTheOriginalForEveryCorpusInput() {
    for input in Self.corpus {
      let expected = Self.pristine(input)
      #expect(
        AgentSessionFingerprintMatcher.normalize(input) == expected,
        "normalize diverged for \(String(reflecting: input))"
      )
      #expect(
        AgentSessionFingerprintMatcher.normalizeGeneral(input) == expected,
        "normalizeGeneral diverged for \(String(reflecting: input))"
      )
    }
  }

  @Test func fastPathMatchesReferenceForRandomASCII() {
    // Random byte soup over the interesting ASCII range catches sequence shapes
    // the hand-written corpus does not enumerate.
    var generator = SeededGenerator(seed: 0x5EED_1234)
    let alphabet: [Character] = Array("abzAZ019 \t\n\r\u{000B}\u{000C}[;?@~\u{001B}mJq/ ")
    for _ in 0..<2000 {
      let length = Int.random(in: 0...40, using: &generator)
      let input = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
      let expected = Self.pristine(input)
      #expect(
        AgentSessionFingerprintMatcher.normalize(input) == expected,
        "normalize diverged for \(String(reflecting: input))"
      )
      #expect(
        AgentSessionFingerprintMatcher.normalizeGeneral(input) == expected,
        "normalizeGeneral diverged for \(String(reflecting: input))"
      )
    }
  }

  @Test func fastPathMatchesReferenceForEveryASCIIByteAndPair() {
    let scalars = (UInt8.min...UInt8.max).prefix(128).map { String(Unicode.Scalar($0)) }
    for first in scalars {
      #expect(AgentSessionFingerprintMatcher.normalize(first) == Self.pristine(first))
      for second in scalars {
        let input = first + second
        #expect(
          AgentSessionFingerprintMatcher.normalize(input) == Self.pristine(input),
          "normalize diverged for \(String(reflecting: input))"
        )
      }
    }
  }

  @Test func normalizesToExpectedText() {
    #expect(AgentSessionFingerprintMatcher.normalize("  \u{001B}[1;31mHello\t\tWORLD  ") == "hello world")
    #expect(AgentSessionFingerprintMatcher.normalize("") == "")
    #expect(AgentSessionFingerprintMatcher.normalize("   ") == "")
  }
}

/// Deterministic generator so a divergence is reproducible from the seed.
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
  }
}
