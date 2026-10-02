import ComposableArchitecture
import CustomDump
import Foundation
import Sentry

extension Reducer where State: Equatable {
  @ReducerBuilder<State, Action>
  func logActions() -> some Reducer<State, Action> {
    LogActionsReducer(base: self)
  }
}

/// When set, `LogActionsReducer` labels every action and logs it to the unified
/// log, plus prints a `CustomDump` state diff. Off by default: the label
/// reflection (`debugCaseOutput`) together with a full app-state snapshot and a
/// deep `==` compare run on *every* action, which stack sampling measured as a
/// steady main-thread cost under heavy action throughput. Enable per launch with
/// `PROWL_LOG_TCA_ACTIONS=1` (Xcode scheme env var, or `open` with the variable
/// exported) to trace the stream via `make log-stream`.
#if DEBUG
  private let tcaActionLoggingEnabled =
    ProcessInfo.processInfo.environment["PROWL_LOG_TCA_ACTIONS"] == "1"
#endif

struct LogActionsReducer<Base: Reducer>: Reducer where Base.State: Equatable {
  let base: Base

  private let logger = SupaLogger("TCA")

  func reduce(into state: inout Base.State, action: Base.Action) -> Effect<Base.Action> {
    #if DEBUG
      guard tcaActionLoggingEnabled else {
        return base._reduce(into: &state, action: action)
      }
      let actionLabel = debugCaseOutput(action)
      // `notice`, not `debug`: in DEBUG `SupaLogger.debug` prints to a stdout
      // that a Finder/launchd-launched app discards, so `make log-stream` would
      // never see it. `notice` routes to the unified log in all configs.
      logger.notice("Action: \(actionLabel)")
      let previousState = state
      let effects = base._reduce(into: &state, action: action)
      if previousState != state, let diff = CustomDump.diff(previousState, state) {
        print(diff)
      }
      return effects
    #else
      let actionLabel = releaseActionLabel(action)
      logger.debug("Action: \(actionLabel)")
      SentrySDK.logger.info("Action: \(actionLabel)")
      let breadcrumb = Breadcrumb(level: .debug, category: "action")
      breadcrumb.message = actionLabel
      SentrySDK.addBreadcrumb(breadcrumb)
      return base._reduce(into: &state, action: action)
    #endif
  }
}

func debugCaseOutput(
  _ value: Any,
  abbreviated: Bool = false
) -> String {
  func debugCaseOutputHelp(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .enum:
      guard let child = mirror.children.first else {
        let childOutput = "\(value)"
        return childOutput == "\(typeName(type(of: value)))" ? "" : ".\(childOutput)"
      }
      let childOutput = debugCaseOutputHelp(child.value)
      return ".\(child.label ?? "")\(childOutput.isEmpty ? "" : "(\(childOutput))")"
    case .tuple:
      return mirror.children.map { label, value in
        let childOutput = debugCaseOutputHelp(value)
        let labelValue = label.map { isUnlabeledArgument($0) ? "_:" : "\($0):" } ?? ""
        let suffix = childOutput.isEmpty ? "" : " \(childOutput)"
        return "\(labelValue)\(suffix)"
      }
      .joined(separator: ", ")
    default:
      return ""
    }
  }

  return (value as? any CustomDebugStringConvertible)?.debugDescription
    ?? "\(abbreviated ? "" : typeName(type(of: value)))\(debugCaseOutputHelp(value))"
}

func releaseActionLabel(_ value: Any) -> String {
  let rootType = shortTypeName(type(of: value))
  let casePath = releaseEnumCasePath(value)
  guard !casePath.isEmpty else {
    return rootType
  }
  return "\(rootType).\(casePath.joined(separator: "."))"
}

private func isUnlabeledArgument(_ label: String) -> Bool {
  label.firstIndex(where: { $0 != "." && !$0.isNumber }) == nil
}

private func releaseEnumCasePath(_ value: Any) -> [String] {
  var labels: [String] = []
  var currentValue = value

  while true {
    let mirror = Mirror(reflecting: currentValue)
    guard mirror.displayStyle == .enum else {
      return labels
    }
    if let child = mirror.children.first, let label = child.label {
      labels.append(label)
      let childMirror = Mirror(reflecting: child.value)
      guard childMirror.displayStyle == .enum else {
        return labels
      }
      currentValue = child.value
    } else {
      labels.append(caseName(String(describing: currentValue)))
      return labels
    }
  }
}

private func caseName(_ description: String) -> String {
  if let parenIndex = description.firstIndex(of: "(") {
    return String(description[..<parenIndex])
  }
  return description
}

private func shortTypeName(_ type: Any.Type) -> String {
  let components = String(reflecting: type)
    .split(separator: ".")
    .filter { !$0.hasPrefix("(unknown context at $") }
    .suffix(2)
  return components.isEmpty ? String(reflecting: type) : components.joined(separator: ".")
}

private func typeName(
  _ type: Any.Type,
  qualified: Bool = true,
  genericsAbbreviated: Bool = true
) -> String {
  var name = _typeName(type, qualified: qualified)
    .replacing(#/\(unknown context at \$[0-9A-Fa-f]+\)\./#, with: "")
  for _ in 1...10 {
    let abbreviated =
      name
      .replacing(#/\bSwift\.Optional<([^><]+)>/#) { match in
        "\(match.1)?"
      }
      .replacing(#/\bSwift\.Array<([^><]+)>/#) { match in
        "[\(match.1)]"
      }
      .replacing(#/\bSwift\.Dictionary<([^,<]+), ([^><]+)>/#) { match in
        "[\(match.1): \(match.2)]"
      }
    if abbreviated == name { break }
    name = abbreviated
  }
  name = name.replacing(#/\w+\.([\w.]+)/#) { match in
    "\(match.1)"
  }
  if genericsAbbreviated {
    name = name.replacing(#/<.+>/#, with: "")
  }
  return name
}
