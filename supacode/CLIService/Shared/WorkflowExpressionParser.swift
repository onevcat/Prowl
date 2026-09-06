import Foundation

nonisolated struct WorkflowExpressionParser {
  private var tokens: [String] = []
  private var offset = 0
  private var depth = 0
  private static let precedence = [
    "??": 1, "||": 2, "&&": 3, "==": 4, "!=": 4,
    "<": 5, "<=": 5, ">": 5, ">=": 5, "+": 6, "-": 6, "*": 7, "/": 7, "%": 7,
  ]

  init(_ source: String) throws {
    guard source.utf8.count <= 16_384 else { throw WorkflowExpressionError.limit("Expression exceeds 16 KiB.") }
    var remaining = source[...]
    let token =
      #/
      \s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|
      [0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|[a-zA-Z_][a-zA-Z0-9_]*|
      \?\?|\|\||&&|==|!=|<=|>=|[.\[\](),!+*\/%<>-])
      /#
    while !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let match = remaining.prefixMatch(of: token) else {
        throw WorkflowExpressionError.syntax("Invalid token near '\(remaining.prefix(30))'.")
      }
      guard tokens.count < 256 else { throw WorkflowExpressionError.limit("Expression exceeds 256 tokens.") }
      tokens.append(String(match.1))
      remaining = remaining[match.range.upperBound...]
    }
  }

  mutating func parse() throws -> WorkflowExpressionNode {
    let result = try expression()
    guard offset == tokens.count else { throw WorkflowExpressionError.syntax("Unexpected token '\(peek)'.") }
    return result
  }

  private var peek: String { offset < tokens.count ? tokens[offset] : "" }

  @discardableResult private mutating func consume(_ token: String) -> Bool {
    guard peek == token else { return false }
    offset += 1
    return true
  }

  private mutating func require(_ token: String) throws {
    guard consume(token) else { throw WorkflowExpressionError.syntax("Expected '\(token)'.") }
  }

  private mutating func expression(_ minimum: Int = 1) throws -> WorkflowExpressionNode {
    depth += 1
    defer { depth -= 1 }
    guard depth <= 64 else { throw WorkflowExpressionError.limit("Expression nesting exceeds 64.") }
    var left = try primary()
    while let precedence = Self.precedence[peek], precedence >= minimum {
      let operation = peek
      offset += 1
      let right = try expression(precedence + 1)
      left = .binary(operation, left, right)
    }
    return left
  }

  private mutating func primary() throws -> WorkflowExpressionNode {
    var value: WorkflowExpressionNode
    if consume("!") { return try .unary("!", expression(8)) }
    if consume("-") { return try .unary("-", expression(8)) }
    if consume("(") {
      value = try expression()
      try require(")")
    } else if consume("[") {
      value = try .array(arguments(ending: "]"))
    } else {
      value = try atom()
    }
    while true {
      if consume(".") {
        let name = peek
        guard name.wholeMatch(of: /[a-zA-Z_][a-zA-Z0-9_]*/) != nil else {
          throw WorkflowExpressionError.syntax("Expected a field name.")
        }
        offset += 1
        value = .field(value, name)
      } else if consume("[") {
        value = try .index(value, expression())
        try require("]")
      } else {
        break
      }
    }
    return value
  }

  private mutating func atom() throws -> WorkflowExpressionNode {
    let token = peek
    guard !token.isEmpty else { throw WorkflowExpressionError.syntax("Expected an expression.") }
    offset += 1
    switch token {
    case "true": return .literal(.boolean(true))
    case "false": return .literal(.boolean(false))
    case "null": return .literal(.null)
    default: break
    }
    if token.hasPrefix("\"") {
      return try .literal(.string(JSONDecoder().decode(String.self, from: Data(token.utf8))))
    }
    if token.hasPrefix("'") {
      let body = String(token.dropFirst().dropLast()).replacing("\\'", with: "'")
      return .literal(.string(body))
    }
    if let integer = Int(token) {
      let value = WorkflowJSONValue.integer(integer)
      try WorkflowJSON.validate(value)
      return .literal(value)
    }
    if let number = Double(token) {
      let value = WorkflowJSONValue.number(number)
      try WorkflowJSON.validate(value)
      return .literal(value)
    }
    guard token.wholeMatch(of: /[a-zA-Z_][a-zA-Z0-9_]*/) != nil else {
      throw WorkflowExpressionError.syntax("Unexpected token '\(token)'.")
    }
    if consume("(") { return try .call(token, arguments(ending: ")")) }
    return .name(token)
  }

  private mutating func arguments(ending: String) throws -> [WorkflowExpressionNode] {
    if consume(ending) { return [] }
    var result = [try expression()]
    while consume(",") { result.append(try expression()) }
    try require(ending)
    return result
  }
}
