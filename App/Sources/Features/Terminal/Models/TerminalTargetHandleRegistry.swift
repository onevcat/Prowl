import Foundation

@MainActor
final class TerminalTargetHandleRegistry {
  private var tabHandles: [TerminalTabID: Int] = [:]
  private var paneHandles: [UUID: Int] = [:]
  private var nextHandle: Int

  init(firstHandle: Int = 1) {
    precondition(firstHandle > 0)
    nextHandle = firstHandle
  }

  func register(tabID: TerminalTabID) -> Int {
    if let handle = tabHandles[tabID] {
      return handle
    }
    let handle = allocateHandle()
    tabHandles[tabID] = handle
    return handle
  }

  func register(paneID: UUID) -> Int {
    if let handle = paneHandles[paneID] {
      return handle
    }
    let handle = allocateHandle()
    paneHandles[paneID] = handle
    return handle
  }

  func handle(for tabID: TerminalTabID) -> Int? {
    tabHandles[tabID]
  }

  func handle(for paneID: UUID) -> Int? {
    paneHandles[paneID]
  }

  func unregister(tabID: TerminalTabID) {
    tabHandles.removeValue(forKey: tabID)
  }

  func unregister(paneID: UUID) {
    paneHandles.removeValue(forKey: paneID)
  }

  private func allocateHandle() -> Int {
    let handle = nextHandle
    nextHandle += 1
    return handle
  }
}
