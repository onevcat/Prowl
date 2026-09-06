import Foundation

nonisolated public enum WorkflowJSONValue: Codable, Equatable, Sendable {
  case null
  case boolean(Bool)
  case integer(Int)
  case number(Double)
  case string(String)
  case array([WorkflowJSONValue])
  case object([String: WorkflowJSONValue])

  public static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null): true
    case (.boolean(let left), .boolean(let right)): left == right
    case (.integer(let left), .integer(let right)): left == right
    case (.number(let left), .number(let right)): left == right
    case (.integer(let left), .number(let right)): Double(left) == right
    case (.number(let left), .integer(let right)): left == Double(right)
    case (.string(let left), .string(let right)): left == right
    case (.array(let left), .array(let right)): left == right
    case (.object(let left), .object(let right)): left == right
    default: false
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let boolValue = try? container.decode(Bool.self) {
      self = .boolean(boolValue)
    } else if let intValue = try? container.decode(Int.self) {
      self = .integer(intValue)
    } else if let doubleValue = try? container.decode(Double.self) {
      self = .number(doubleValue)
    } else if let stringValue = try? container.decode(String.self) {
      self = .string(stringValue)
    } else if let arrayValue = try? container.decode([WorkflowJSONValue].self) {
      self = .array(arrayValue)
    } else if let objectValue = try? container.decode([String: WorkflowJSONValue].self) {
      self = .object(objectValue)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .boolean(let boolValue): try container.encode(boolValue)
    case .integer(let intValue): try container.encode(intValue)
    case .number(let doubleValue): try container.encode(doubleValue)
    case .string(let stringValue): try container.encode(stringValue)
    case .array(let arrayValue): try container.encode(arrayValue)
    case .object(let objectValue): try container.encode(objectValue)
    }
  }
}

nonisolated public enum WorkflowExpressionError: Error, Equatable, Sendable {
  case syntax(String)
  case missing(String)
  case type(String)
  case limit(String)
}

nonisolated public enum WorkflowJSON {
  public static func object(_ values: [String: WorkflowJSONValue]) -> WorkflowJSONValue {
    var fields = WorkflowJSONValue.object([:])
    if case .object(var object) = fields {
      for (key, value) in values { object[key] = value }
      fields = .object(object)
    }
    return fields
  }

  public static let maximumInteger = 9_007_199_254_740_991

  public static func validate(_ value: WorkflowJSONValue, depth: Int = 0) throws {
    guard depth <= 64 else { throw WorkflowExpressionError.limit("JSON nesting exceeds 64.") }
    switch value {
    case .integer(let number):
      guard (-maximumInteger...maximumInteger).contains(number) else {
        throw WorkflowExpressionError.limit("Integer exceeds the exact JSON range.")
      }
    case .number(let number):
      guard number.isFinite else { throw WorkflowExpressionError.type("Number must be finite.") }
    case .array(let values):
      for child in values { try validate(child, depth: depth + 1) }
    case .object(let values):
      for child in values.values { try validate(child, depth: depth + 1) }
    default: break
    }
  }

  public static func scalarText(_ value: WorkflowJSONValue) throws -> String {
    switch value {
    case .string(let text): return text
    case .integer(let number): return String(number)
    case .number(let number): return String(number)
    case .boolean(let flag): return flag ? "true" : "false"
    case .null: return "null"
    case .array, .object: throw WorkflowExpressionError.type("Text interpolation requires a scalar.")
    }
  }
}

nonisolated extension WorkflowJSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}
