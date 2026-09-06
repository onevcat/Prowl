import Foundation

nonisolated public struct WorkflowStateDeclaration: Equatable, Sendable {
  public let type: String
  public let initial: WorkflowJSONValue

  public init(type: String, initial: WorkflowJSONValue) {
    self.type = type
    self.initial = initial
  }
}

nonisolated public struct WorkflowTypedState: Equatable, Sendable {
  public let declarations: [String: WorkflowStateDeclaration]
  public private(set) var values: [String: WorkflowJSONValue]

  public init(declarations: [String: WorkflowStateDeclaration] = [:]) throws {
    self.declarations = declarations
    values = [:]
    for (name, declaration) in declarations {
      guard WorkflowSchema.isSlug(name) else { throw WorkflowExpressionError.type("Invalid state name: \(name).") }
      try Self.check(declaration.initial, type: declaration.type)
      values[name] = declaration.initial
    }
  }

  public mutating func assign(_ assignments: [String: String], values context: [String: WorkflowJSONValue]) throws {
    var snapshot = context
    var object = WorkflowJSONValue.object([:])
    if case .object(var fields) = object {
      for (key, value) in values { fields[key] = value }
      object = .object(fields)
    }
    snapshot["state"] = object
    var candidate = values
    for name in assignments.keys.sorted() {
      guard let declaration = declarations[name], let expression = assignments[name] else {
        throw WorkflowExpressionError.type("Unknown state field: \(name).")
      }
      let value = try WorkflowExpression.evaluate(expression, values: snapshot)
      try Self.check(value, type: declaration.type)
      candidate[name] = value
    }
    values = candidate
  }

  public static func check(_ value: WorkflowJSONValue, type: String, depth: Int = 0) throws {
    guard depth <= 16 else { throw WorkflowExpressionError.limit("State array nesting exceeds 16.") }
    try WorkflowJSON.validate(value)
    if type.hasPrefix("array<"), type.hasSuffix(">") {
      guard case .array(let items) = value else { throw WorkflowExpressionError.type("Expected \(type).") }
      let itemType = String(type.dropFirst(6).dropLast())
      // Check the declaration even when the initial array is empty.
      try validateType(itemType, depth: depth + 1)
      for item in items { try check(item, type: itemType, depth: depth + 1) }
      return
    }
    let valid: Bool
    switch (type, value) {
    case ("boolean", .boolean), ("integer", .integer), ("number", .number),
      ("number", .integer), ("string", .string):
      valid = true
    default: valid = false
    }
    guard valid else { throw WorkflowExpressionError.type("Expected \(type).") }
  }

  private static func validateType(_ type: String, depth: Int) throws {
    guard depth <= 16 else { throw WorkflowExpressionError.limit("State array nesting exceeds 16.") }
    if ["boolean", "integer", "number", "string"].contains(type) { return }
    if type.hasPrefix("array<"), type.hasSuffix(">") {
      try validateType(String(type.dropFirst(6).dropLast()), depth: depth + 1)
      return
    }
    throw WorkflowExpressionError.type("Unknown state type: \(type).")
  }
}
