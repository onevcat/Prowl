import Foundation

nonisolated struct CodexLogDecoder: Sendable {
  enum Failure: Error { case invalidRecord }
  let sessionID: String
  var isLive = false

  private var followups: Set<String> = []

  init(sessionID: String, isLive: Bool = false) {
    self.sessionID = sessionID
    self.isLive = isLive
  }

  mutating func consume(_ data: Data, root: String) throws -> [AgentDetectionEvent] {
    guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = record["type"] as? String,
      let payload = record["payload"] as? [String: Any]
    else { throw Failure.invalidRecord }
    if type == "event_msg", payload["type"] as? String == "thread_settings_applied",
      payload["thread_id"] as? String == sessionID
    {
      isLive = true
      return []
    }
    guard isLive else { return [] }
    if type == "response_item", payload["type"] as? String == "function_call",
      payload["namespace"] as? String == "collaboration", payload["name"] as? String == "followup_task",
      let call = payload["call_id"] as? String
    {
      guard followups.count < 128 else { throw Failure.invalidRecord }
      followups.insert(call)
      return []
    }
    guard type == "event_msg", let event = payload["type"] as? String else { return [] }
    switch event {
    case "task_started", "task_complete", "turn_aborted":
      guard let turn = payload["turn_id"] as? String, !turn.isEmpty else { throw Failure.invalidRecord }
      if sessionID == root {
        return [
          event == "task_started" ? .turnStarted(session: root, turn: turn) : .turnEnded(session: root, turn: turn)
        ]
      }
      return [
        event == "task_started"
          ? .childStarted(root: root, child: sessionID, work: turn)
          : .childEnded(root: root, child: sessionID, work: turn)
      ]
    case "item_completed":
      return try childActivity(payload, root: root)
    default:
      return []
    }
  }
  private mutating func childActivity(_ payload: [String: Any], root: String) throws -> [AgentDetectionEvent] {
    guard let item = payload["item"] as? [String: Any], item["type"] as? String == "SubAgentActivity" else {
      return []
    }
    guard let kind = item["kind"] as? String, let child = item["agent_thread_id"] as? String,
      let id = item["id"] as? String
    else { throw Failure.invalidRecord }
    switch kind {
    case "started":
      return [.childScheduled(root: root, child: child, work: "pending:" + id)]
    case "interacted":
      return followups.remove(id) == nil ? [] : [.childScheduled(root: root, child: child, work: "pending:" + id)]
    case "completed":
      guard id.hasPrefix("subagent-completed-") else { throw Failure.invalidRecord }
      return [.childEnded(root: root, child: child, work: String(id.dropFirst("subagent-completed-".count)))]
    case "interrupted":
      // The child's own turn_aborted supplies the work ID. A parent interrupt
      // request has a call ID, which must not cancel a later reused child turn.
      return []
    default:
      throw Failure.invalidRecord
    }
  }

}
