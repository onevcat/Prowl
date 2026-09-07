// ProwlShared/WorkflowTemplate.swift
// Static reference paths and template delimiter scanning.
// WorkflowExpression parses and evaluates the expressions inside each delimiter pair.

import Foundation

nonisolated public enum WorkflowTemplate {
  public struct Reference: Equatable, Sendable {
    /// The dotted path as written, e.g. `deliveries.findings.path`.
    public let path: String
    public let components: [String]

    public init(path: String) {
      self.path = path
      components = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }
  }

  public enum ScanError: Error, Equatable, Sendable {
    case unbalanced
    case emptyReference
    case invalidPath(String)
  }

  private static var referencePattern: Regex<(Substring, Substring)> { /\{\{([^{}]*)\}\}/ }
  private static var pathPattern: Regex<Substring> { /^[a-z0-9_.-]+$/ }

  public static func containsReference(_ text: String) -> Bool {
    text.contains("{{")
  }

  /// Every reference in document order. Throws on an unbalanced or malformed placeholder.
  public static func references(in text: String) throws(ScanError) -> [Reference] {
    var references: [Reference] = []
    var remainder = Substring(text)
    while let match = remainder.firstMatch(of: referencePattern) {
      let path = match.1.trimmingCharacters(in: .whitespaces)
      guard !path.isEmpty else { throw .emptyReference }
      guard path.wholeMatch(of: pathPattern) != nil else { throw .invalidPath(path) }
      references.append(Reference(path: path))
      remainder = remainder[match.range.upperBound...]
    }
    if remainder.contains("{{") || remainder.contains("}}") {
      throw .unbalanced
    }
    return references
  }

  /// True when the whole string is exactly one reference (surrounding whitespace allowed).
  public static func isSingleReference(_ text: String) -> Bool {
    guard let match = text.wholeMatch(of: /\s*\{\{([^{}]*)\}\}\s*/) else { return false }
    return !match.1.trimmingCharacters(in: .whitespaces).isEmpty
  }
}
