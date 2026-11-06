import Foundation

nonisolated enum MirrorInputRoute {
  static func command(listing: MirrorJSON, paneID: UUID, text: String) throws -> MirrorCommandRequest.Command {
    let result = try listing.decode(Listing.self)
    guard result.ok, let item = result.data?.items.first(where: { UUID(uuidString: $0.pane.id) == paneID }) else {
      throw Refusal.missing
    }
    if item.pane.agent != nil { return .agentsInput(.init(pane: paneID.uuidString, prompt: text)) }
    // `task.status` is the whole worktree's; the Host checks that this pane's shell is at its prompt.
    return .send(.init(pane: paneID, text: text))
  }

  private enum Refusal: LocalizedError {
    case missing
    var errorDescription: String? { "The target could not be verified." }
  }
  private struct Listing: Decodable {
    struct Payload: Decodable {
      struct Item: Decodable {
        struct Pane: Decodable { let id: String; let agent: String? }
        let pane: Pane
      }
      let items: [Item]
    }
    let ok: Bool
    let data: Payload?
  }
}
