import Foundation
import Yams

/// Decode YAML scalars by their syntax. Generic Decoder string coercion would erase JSON types.
nonisolated enum WorkflowYAMLValue {
  static func validateStructure(_ root: Node) throws {
    var pending: [(Node, Int)] = [(root, 0)]
    while let (node, depth) = pending.popLast() {
      guard depth <= 64 else { throw WorkflowExpressionError.limit("YAML nesting exceeds 64.") }
      switch node {
      case .mapping(let fields):
        for (key, child) in fields {
          pending.append((key, depth + 1))
          pending.append((child, depth + 1))
        }
      case .sequence(let items):
        for child in items { pending.append((child, depth + 1)) }
      case .alias: throw WorkflowExpressionError.syntax("YAML aliases are not supported.")
      case .scalar: break
      }
    }
  }

  static func parse(_ source: String) throws -> WorkflowJSONValue {
    guard let node = try Yams.compose(yaml: source) else { throw WorkflowExpressionError.syntax("Empty document.") }
    return try decode(node)
  }

  static func decode(_ node: Node, depth: Int = 0) throws -> WorkflowJSONValue {
    guard depth <= 64 else { throw WorkflowExpressionError.limit("YAML nesting exceeds 64.") }
    let value: WorkflowJSONValue
    switch node {
    case .alias: throw WorkflowExpressionError.syntax("YAML aliases are not supported in typed values.")
    case .mapping(let mapping):
      var object = WorkflowJSONValue.object([:])
      if case .object(var fields) = object {
        for (key, child) in mapping {
          guard case .scalar(let name) = key, fields[name.string] == nil else {
            throw WorkflowExpressionError.syntax("Mapping keys must be unique strings.")
          }
          fields[name.string] = try decode(child, depth: depth + 1)
        }
        object = .object(fields)
      }
      value = object
    case .sequence(let sequence): value = try .array(sequence.map { try decode($0, depth: depth + 1) })
    case .scalar(let scalar):
      if scalar.style != .plain && scalar.style != .any { return .string(scalar.string) }
      if node.null != nil {
        value = .null
      } else if let boolean = node.bool {
        value = .boolean(boolean)
      } else if let integer = node.int {
        value = .integer(integer)
      } else if let number = node.float {
        value = .number(number)
      } else {
        value = .string(scalar.string)
      }
    }
    try WorkflowJSON.validate(value)
    return value
  }
}
