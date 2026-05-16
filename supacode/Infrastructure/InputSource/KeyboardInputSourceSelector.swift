import Carbon
import Foundation

@MainActor
internal protocol KeyboardInputSourceSelecting: AnyObject {
  func currentInputSourceID() -> String?
  func selectInputSource(id: String) -> Bool
  func selectABC() -> Bool
}

@MainActor
internal final class KeyboardInputSourceSelector: KeyboardInputSourceSelecting {
  internal static let abcInputSourceID = "com.apple.keylayout.ABC"

  private let logger = SupaLogger("InputSource")

  internal func currentInputSourceID() -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
      logger.warning("currentInputSourceID missing current keyboard input source")
      return nil
    }

    return inputSourceID(source)
  }

  internal func selectABC() -> Bool {
    selectInputSource(id: Self.abcInputSourceID)
  }

  internal func selectInputSource(id: String) -> Bool {
    if currentInputSourceID() == id {
      return true
    }

    guard let source = inputSource(for: id) else {
      logger.warning("selectInputSource failed to find source id=\(id)")
      return false
    }

    let status = TISSelectInputSource(source)
    if status != noErr {
      logger.warning("selectInputSource failed id=\(id) status=\(status)")
    }
    return status == noErr
  }

  private func inputSource(for id: String) -> TISInputSource? {
    let properties = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let list = TISCreateInputSourceList(properties, false)?.takeRetainedValue() as? [TISInputSource] else {
      return nil
    }
    return list.first
  }

  private func inputSourceID(_ source: TISInputSource) -> String? {
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
      return nil
    }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
  }
}
