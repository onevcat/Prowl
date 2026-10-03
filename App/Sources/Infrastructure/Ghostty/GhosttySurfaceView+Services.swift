import AppKit
import GhosttyKit

extension GhosttySurfaceView: NSServicesMenuRequestor {
  override func validRequestor(
    forSendType sendType: NSPasteboard.PasteboardType?,
    returnType: NSPasteboard.PasteboardType?
  ) -> Any? {
    let receivable: [NSPasteboard.PasteboardType] = [.string, .init("public.utf8-plain-text")]
    let sendable = receivable
    let sendableRequiresSelection = sendable

    if (returnType == nil || receivable.contains(returnType!))
      && (sendType == nil || sendable.contains(sendType!))
    {
      if let sendType, sendableRequiresSelection.contains(sendType) {
        if surface == nil || !ghostty_surface_has_selection(surface) {
          return super.validRequestor(forSendType: sendType, returnType: returnType)
        }
      }
      return self
    }
    return super.validRequestor(forSendType: sendType, returnType: returnType)
  }

  func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    guard let surface else { return false }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return false }
    defer { ghostty_surface_free_text(surface, &text) }
    pboard.declareTypes([.string], owner: nil)
    pboard.setString(Self.string(from: text), forType: .string)
    return true
  }

  func readSelection(from pboard: NSPasteboard) -> Bool {
    guard let str = pboard.getOpinionatedStringContents() else { return false }
    let len = str.utf8CString.count
    if len == 0 { return true }
    str.withCString { ptr in
      ghostty_surface_text(surface, ptr, UInt(len - 1))
    }
    return true
  }
}
