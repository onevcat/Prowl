import Foundation
import GhosttyKit

@MainActor
struct GhosttyMirrorPaneSource: MirrorPaneSource {
  let manager: WorktreeTerminalManager

  func panes() -> [MirrorPaneDescriptor] {
    manager.activeWorktreeStates.flatMap { state in
      state.surfaces.values.filter { $0.surface != nil }.map { view in
        MirrorPaneDescriptor(
          id: view.id, title: "\(state.worktree.name) · \(view.id.uuidString.prefix(8))",
          directory: state.worktree.workingDirectory.path, busy: false)
      }
    }.sorted { $0.title < $1.title }
  }

  func snapshot(_ id: UUID) throws -> MirrorFrame {
    guard let terminal = view(id)?.surface else { throw MirrorProtocolError.invalidMessage }
    let size = ghostty_surface_size(terminal)
    guard size.columns > 0, size.rows > 0 else { throw MirrorProtocolError.invalidMessage }
    var text = ghostty_text_s()
    guard ghostty_surface_read_snapshot(terminal, &text) else { throw MirrorProtocolError.invalidMessage }
    defer { ghostty_surface_free_text(terminal, &text) }
    guard text.text_len <= MirrorWire.maximumPayload / 2, let bytes = text.text else {
      throw MirrorProtocolError.messageTooLarge
    }
    return MirrorFrame(
      columns: UInt32(size.columns), rows: UInt32(size.rows),
      bytes: Data(bytes: bytes, count: Int(text.text_len)))
  }

  func write(_ bytes: Data, to id: UUID) throws {
    guard let terminal = view(id)?.surface else { throw MirrorProtocolError.invalidMessage }
    // The text action accepts a length-delimited byte buffer. Its escape parser
    // UTF-8-encodes \xNN, so preserve bytes (even split UTF-8) and escape only '\'.
    // The surface text API is unsuitable here because it applies paste encoding again.
    var action = Data("text:".utf8)
    for byte in bytes {
      action.append(byte)
      if byte == 0x5C { action.append(byte) }
    }
    let written = action.withUnsafeBytes {
      ghostty_surface_binding_action(terminal, $0.baseAddress!.assumingMemoryBound(to: CChar.self), UInt($0.count))
    }
    guard written else {
      throw MirrorProtocolError.invalidMessage
    }
  }

  func retainedText(_ id: UUID) throws -> String {
    guard let text = view(id)?.readScreenContentsForCLI() else { throw MirrorProtocolError.invalidMessage }
    return text
  }

  private func view(_ id: UUID) -> GhosttySurfaceView? {
    manager.activeWorktreeStates.lazy.compactMap { $0.surfaces[id] }.first
  }
}
