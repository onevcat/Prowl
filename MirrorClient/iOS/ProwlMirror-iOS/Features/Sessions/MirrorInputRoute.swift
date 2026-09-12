import Foundation

nonisolated enum MirrorInputRoute {
  static func command(listing: MirrorJSON, paneID: UUID, text: String) throws -> MirrorCommandRequest.Command {
    let result = try listing.decode(Listing.self)
    guard result.ok, let item = result.data?.items.first(where: { UUID(uuidString: $0.pane.id) == paneID }) else {
      throw Refusal.missing
    }
    if item.pane.agent != nil { return .agentsDispatch(.init(pane: paneID.uuidString, prompt: text)) }
    guard item.task.status == "idle" else { throw Refusal.busy }
    return .send(.init(pane: paneID, text: text))
  }

  private enum Refusal: LocalizedError {
    case missing, busy
    var errorDescription: String? {
      switch self {
      case .missing: "The target could not be verified."
      case .busy: "Shell task is running or its state is unknown."
      }
    }
  }
  private struct Listing: Decodable {
    struct Payload: Decodable {
      struct Item: Decodable {
        struct Pane: Decodable { let id: String; let agent: String? }
        struct TaskState: Decodable { let status: String? }
        let pane: Pane
        let task: TaskState
      }
      let items: [Item]
    }
    let ok: Bool
    let data: Payload?
  }
}
