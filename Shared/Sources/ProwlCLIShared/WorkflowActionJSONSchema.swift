import Foundation
import JSONSchema

/// A schema and its bundle-local resources. Validation never fetches a URL.
nonisolated public struct WorkflowActionJSONSchema: Equatable, Sendable {
  public let raw: WorkflowJSONValue
  private let base: URL
  private let resources: [String: WorkflowJSONValue]

  public init(_ raw: WorkflowJSONValue, path: String, files: [String: Data] = [:]) throws {
    guard case .object(let fields) = raw, fields["type"] == .string("object") else {
      throw WorkflowExpressionError.type("Action schema root must declare type: object.")
    }
    var resolver = WorkflowSchemaResources(files: files)
    base = URL(string: "https://pwl.invalid/bundle/")!.appending(path: path)
    self.raw = try resolver.resolve(raw, base: base)
    resources = resolver.resources
    guard try schema().validateAgainstMetaSchema().isValid else {
      throw WorkflowExpressionError.type("Action contains an invalid JSON Schema.")
    }
    for (path, resource) in resources {
      let schema = try Schema(
        rawSchema: Self.convert(resource), context: .init(dialect: .draft2020_12),
        baseURI: URL(string: path)!)
      guard try schema.validateAgainstMetaSchema().isValid else {
        throw WorkflowExpressionError.type("Invalid schema resource: \(path).")
      }
    }
  }

  public func validate(_ value: WorkflowJSONValue) throws {
    guard case .object = value else { throw WorkflowExpressionError.type("Action value must be a JSON object.") }
    try WorkflowJSON.validate(value)
    guard try schema().validate(Self.convert(value)).isValid else {
      throw WorkflowExpressionError.type("Action value does not match its schema.")
    }
  }

  private func schema() throws -> Schema {
    try Schema(
      rawSchema: Self.convert(raw),
      context: .init(dialect: .draft2020_12, remoteSchema: resources.mapValues(Self.convert)), baseURI: base)
  }

  private static func convert(_ value: WorkflowJSONValue) throws -> JSONSchema.JSONValue {
    try JSONDecoder().decode(JSONSchema.JSONValue.self, from: JSONEncoder().encode(value))
  }
}

nonisolated private struct WorkflowSchemaResources {
  let files: [String: Data]
  var resources: [String: WorkflowJSONValue] = [:]
  private var loading: Set<String> = []

  init(files: [String: Data]) { self.files = files }

  mutating func resolve(_ raw: WorkflowJSONValue, base: URL) throws -> WorkflowJSONValue {
    try WorkflowJSON.validate(raw)
    switch raw {
    case .object(var fields):
      if fields["$id"] != nil {
        throw WorkflowExpressionError.type("Use bundle-relative $ref and $anchor; action schemas cannot change $id.")
      }
      for (key, value) in fields {
        if ["$ref", "$dynamicRef"].contains(key) {
          guard case .string(let reference) = value, !reference.contains(":"), !reference.hasPrefix("/"),
            !reference.contains("\\"), let resolved = URL(string: reference, relativeTo: base)?.absoluteURL,
            resolved.host == "pwl.invalid", resolved.path.hasPrefix("/bundle/")
          else { throw WorkflowExpressionError.type("Schema references must stay inside the bundle.") }
          if reference.hasPrefix("#") { continue }
          var document = URLComponents(url: resolved, resolvingAgainstBaseURL: true)!
          document.fragment = nil
          let documentURL = document.url!
          let path = String(documentURL.path.dropFirst("/bundle/".count))
          guard let data = files[path] else { throw WorkflowExpressionError.missing("Schema resource '\(path)'.") }
          let identifier = documentURL.absoluteString
          if resources[identifier] == nil, loading.insert(identifier).inserted {
            let resource: WorkflowJSONValue
            if path.hasSuffix(".json") {
              resource = try JSONDecoder().decode(WorkflowJSONValue.self, from: data)
            } else {
              guard let text = String(data: data, encoding: .utf8) else {
                throw WorkflowExpressionError.type("Schema resource must be UTF-8: \(path).")
              }
              resource = try WorkflowYAMLValue.parse(text)
            }
            resources[identifier] = try resolve(resource, base: documentURL)
            loading.remove(identifier)
          }
          fields[key] = .string(resolved.absoluteString)
        } else {
          fields[key] = try resolve(value, base: base)
        }
      }
      return .object(fields)
    case .array(let items): return try .array(items.map { try resolve($0, base: base) })
    default: return raw
    }
  }
}
