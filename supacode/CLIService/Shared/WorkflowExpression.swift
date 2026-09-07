import Foundation

/// Pure expressions are parsed before evaluation, including branches that short-circuit.
nonisolated public enum WorkflowExpression {
  public static func evaluate(_ source: String, values: [String: WorkflowJSONValue]) throws -> WorkflowJSONValue {
    var parser = try WorkflowExpressionParser(source)
    let expression = try parser.parse()
    let value = try expression.evaluate(values)
    try WorkflowJSON.validate(value)
    return value
  }

  public static func renderValue(
    _ value: WorkflowJSONValue, values: [String: WorkflowJSONValue]
  ) throws -> WorkflowJSONValue {
    switch value {
    case .string(let text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}"),
        !trimmed.dropFirst(2).dropLast(2).contains("}}")
      {
        return try evaluate(String(trimmed.dropFirst(2).dropLast(2)), values: values)
      }
      return try .string(renderText(text, values: values))
    case .array(let items): return try .array(items.map { try renderValue($0, values: values) })
    case .object(let fields):
      var result = fields
      for (key, item) in fields { result[key] = try renderValue(item, values: values) }
      return .object(result)
    default: return value
    }
  }

  public static func requiredReferences(in text: String) throws -> [[String]] {
    var remaining = text[...]
    var result: [[String]] = []
    while let start = remaining.range(of: "{{") {
      remaining = remaining[start.upperBound...]
      guard let end = remaining.range(of: "}}") else { throw WorkflowExpressionError.syntax("Unclosed expression.") }
      var parser = try WorkflowExpressionParser(String(remaining[..<end.lowerBound]))
      result += try parser.parse().requiredReferences
      remaining = remaining[end.upperBound...]
    }
    return result
  }

  public static func renderText(_ text: String, values: [String: WorkflowJSONValue]) throws -> String {
    var remaining = text[...]
    var result = ""
    while let start = remaining.range(of: "{{") {
      result += remaining[..<start.lowerBound]
      remaining = remaining[start.upperBound...]
      guard let end = remaining.range(of: "}}") else { throw WorkflowExpressionError.syntax("Unclosed expression.") }
      result += try WorkflowJSON.scalarText(evaluate(String(remaining[..<end.lowerBound]), values: values))
      remaining = remaining[end.upperBound...]
    }
    guard !remaining.contains("}}") else { throw WorkflowExpressionError.syntax("Unexpected expression delimiter.") }
    return result + remaining
  }
}

nonisolated indirect enum WorkflowExpressionNode {
  case literal(WorkflowJSONValue)
  case name(String)
  case field(Self, String)
  case index(Self, Self)
  case array([Self])
  case unary(String, Self)
  case binary(String, Self, Self)
  case call(String, [Self])

  func evaluate(_ values: [String: WorkflowJSONValue]) throws -> WorkflowJSONValue {
    switch self {
    case .literal(let value): return value
    case .name(let name):
      guard let value = values[name] else { throw WorkflowExpressionError.missing(name) }
      return value
    case .field(let parent, let key):
      guard case .object(let fields) = try parent.evaluate(values) else {
        throw WorkflowExpressionError.type("Field access requires an object.")
      }
      guard let value = fields[key] else { throw WorkflowExpressionError.missing(key) }
      return value
    case .index(let parent, let index): return try indexed(parent.evaluate(values), index.evaluate(values))
    case .array(let items): return try .array(items.map { try $0.evaluate(values) })
    case .unary(let operation, let argument):
      let value = try argument.evaluate(values)
      if operation == "!" { return try .boolean(!boolean(value)) }
      return try arithmetic("-", .integer(0), value)
    case .binary(let operation, let left, let right):
      return try binary(operation, left, right, values)
    case .call(let function, let arguments): return try call(function, arguments, values)
    }
  }

  private func indexed(_ parent: WorkflowJSONValue, _ index: WorkflowJSONValue) throws -> WorkflowJSONValue {
    if case .object(let fields) = parent, case .string(let key) = index {
      guard let value = fields[key] else { throw WorkflowExpressionError.missing(key) }
      return value
    }
    guard case .array(let items) = parent, case .integer(let offset) = index else {
      throw WorkflowExpressionError.type("Array index must be an integer.")
    }
    guard items.indices.contains(offset) else { throw WorkflowExpressionError.missing("index \(offset)") }
    return items[offset]
  }

  private func optional(_ node: Self, _ values: [String: WorkflowJSONValue]) throws -> WorkflowJSONValue? {
    do { return try node.evaluate(values) } catch WorkflowExpressionError.missing { return nil }
  }

  private func binary(
    _ operation: String, _ left: Self, _ right: Self, _ values: [String: WorkflowJSONValue]
  ) throws -> WorkflowJSONValue {
    if operation == "??" {
      if let value = try optional(left, values), value != .null { return value }
      return try right.evaluate(values)
    }
    let lhs = try left.evaluate(values)
    if operation == "&&" { return try .boolean(boolean(lhs) && boolean(right.evaluate(values))) }
    if operation == "||" { return try .boolean(boolean(lhs) || boolean(right.evaluate(values))) }
    let rhs = try right.evaluate(values)
    switch operation {
    case "==": return .boolean(lhs == rhs)
    case "!=": return .boolean(lhs != rhs)
    case "<": return try .boolean(number(lhs) < number(rhs))
    case "<=": return try .boolean(number(lhs) <= number(rhs))
    case ">": return try .boolean(number(lhs) > number(rhs))
    case ">=": return try .boolean(number(lhs) >= number(rhs))
    default: return try arithmetic(operation, lhs, rhs)
    }
  }

  private func boolean(_ value: WorkflowJSONValue) throws -> Bool {
    guard case .boolean(let flag) = value else { throw WorkflowExpressionError.type("Expected a boolean.") }
    return flag
  }

  private func number(_ value: WorkflowJSONValue) throws -> Double {
    switch value {
    case .integer(let value): return Double(value)
    case .number(let value): return value
    default: throw WorkflowExpressionError.type("Expected a number.")
    }
  }

  private func arithmetic(
    _ operation: String, _ lhs: WorkflowJSONValue, _ rhs: WorkflowJSONValue
  ) throws -> WorkflowJSONValue {
    if operation == "+", case .string(let left) = lhs, case .string(let right) = rhs {
      return .string(left + right)
    }
    let left = try number(lhs)
    let right = try number(rhs)
    if ["/", "%"].contains(operation), right == 0 { throw WorkflowExpressionError.type("Division by zero.") }
    let result: Double
    switch operation {
    case "+": result = left + right
    case "-": result = left - right
    case "*": result = left * right
    case "/": result = left / right
    case "%": result = left.truncatingRemainder(dividingBy: right)
    default: throw WorkflowExpressionError.syntax("Unknown operator '\(operation)'.")
    }
    guard result.isFinite else { throw WorkflowExpressionError.limit("Numeric overflow.") }
    if case .integer = lhs, case .integer = rhs, operation != "/" {
      guard abs(result) <= Double(WorkflowJSON.maximumInteger) else {
        throw WorkflowExpressionError.limit("Integer overflow.")
      }
      return .integer(Int(result))
    }
    return .number(result)
  }

  private func call(
    _ function: String, _ arguments: [Self], _ values: [String: WorkflowJSONValue]
  ) throws -> WorkflowJSONValue {
    if function == "exists", arguments.count == 1 {
      return try .boolean(optional(arguments[0], values) != nil)
    }
    let args = try arguments.map { try $0.evaluate(values) }
    switch (function, args.count) {
    case ("length", 1):
      switch args[0] {
      case .array(let items): return .integer(items.count)
      case .object(let fields): return .integer(fields.count)
      case .string(let text): return .integer(text.count)
      default: break
      }
    case ("append", 2):
      if case .array(let items) = args[0] { return .array(items + [args[1]]) }
    case ("slice", 3):
      if case .array(let items) = args[0], case .integer(let start) = args[1], case .integer(let end) = args[2],
        start >= 0, end >= start, end <= items.count
      {
        return .array(Array(items[start..<end]))
      }
    default: break
    }
    throw WorkflowExpressionError.type("Invalid function or arguments: \(function).")
  }
}

extension WorkflowExpressionNode {
  /// Every statically named path, including optional and short-circuited accesses.
  var references: [[String]] {
    if let staticPath { return [staticPath] }
    switch self {
    case .literal, .name: return []
    case .field(let parent, _), .unary(_, let parent): return parent.references
    case .index(let parent, let index): return parent.references + index.references
    case .array(let items), .call(_, let items): return items.flatMap(\.references)
    case .binary(_, let left, let right): return left.references + right.references
    }
  }

  var staticPath: [String]? {
    switch self {
    case .name(let name): return [name]
    case .field(let parent, let key): return parent.staticPath.map { $0 + [key] }
    case .index(let parent, .literal(.string(let key))): return parent.staticPath.map { $0 + [key] }
    default: return nil
    }
  }

  private func existingPaths(when truth: Bool) -> [[String]] {
    switch self {
    case .call("exists", let arguments) where truth && arguments.count == 1:
      return arguments[0].staticPath.map { [$0] } ?? []
    case .unary("!", let argument): return argument.existingPaths(when: !truth)
    case .binary("&&", let left, let right) where truth:
      return left.existingPaths(when: true) + right.existingPaths(when: true)
    case .binary("||", let left, let right) where !truth:
      return left.existingPaths(when: false) + right.existingPaths(when: false)
    default: return []
    }
  }

  var requiredReferences: [[String]] {
    if let staticPath { return [staticPath] }
    switch self {
    case .literal, .name: return []
    case .field(let parent, _), .unary(_, let parent): return parent.requiredReferences
    case .index(let parent, let index): return parent.requiredReferences + index.requiredReferences
    case .array(let items): return items.flatMap(\.requiredReferences)
    case .binary("??", _, let right): return right.requiredReferences
    case .binary(let operation, let left, let right) where operation == "&&" || operation == "||":
      let guards = left.existingPaths(when: operation == "&&")
      return left.requiredReferences
        + right.requiredReferences.filter { path in
          !guards.contains { path.starts(with: $0) }
        }
    case .binary(_, let left, let right): return left.requiredReferences + right.requiredReferences
    case .call("exists", _): return []
    case .call(_, let arguments): return arguments.flatMap(\.requiredReferences)
    }
  }
}
