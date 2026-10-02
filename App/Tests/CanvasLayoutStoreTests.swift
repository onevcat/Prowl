import CoreGraphics
import Foundation
import Testing

@testable import supacode

@MainActor
struct CanvasLayoutStoreTests {
  @Test func releasesSynchronouslyWithTaskLocalStorageOutsideATask() async {
    // Swift Testing runs in a Task. A main-queue callback reproduces synchronous
    // UI teardown with thread-local TaskLocal storage instead of task-owned storage.
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          #expect(Thread.isMainThread)
          withUnsafeCurrentTask { #expect($0 == nil) }
          let defaults = makeDefaults()
          defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
          let layouts = ["tab-a": CanvasCardLayout(position: CGPoint(x: 10, y: 20))]

          CanvasLayoutStoreTestLocal.$marker.withValue(1) {
            var store: CanvasLayoutStore? = CanvasLayoutStore(defaults: defaults)
            weak let releasedStore = store
            store?.setCardLayouts(layouts)
            store = nil

            #expect(releasedStore == nil)
            #expect(CanvasLayoutStoreTestLocal.marker == 1)
            #expect(CanvasLayoutStore(defaults: defaults).cardLayouts == layouts)
          }
          #expect(CanvasLayoutStoreTestLocal.marker == 0)
          continuation.resume()
        }
      }
    }
  }

  @Test func loadsLegacyCardLayoutDictionary() throws {
    let defaults = makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let legacyLayouts = [
      "tab-a": CanvasCardLayout(position: CGPoint(x: 10, y: 20), size: CGSize(width: 300, height: 200)),
      "tab-b": CanvasCardLayout(position: CGPoint(x: 30, y: 40), size: CGSize(width: 500, height: 400)),
    ]
    let data = try JSONEncoder().encode(legacyLayouts)
    defaults.set(data, forKey: "canvasCardLayouts")

    let store = CanvasLayoutStore(defaults: defaults)

    #expect(store.cardLayouts == legacyLayouts)
    #expect(Set(store.zOrder) == Set(legacyLayouts.keys))
    #expect(store.shouldAutoArrangeOnInitialEntry(for: ["tab-a", "tab-b"]) == false)
  }

  @Test func skipsInitialAutoArrangeWhenCurrentCardsWereLoadedFromStorage() throws {
    let defaults = makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let store = CanvasLayoutStore(defaults: defaults)
    store.setCardLayouts([
      "tab-a": CanvasCardLayout(position: CGPoint(x: 10, y: 20)),
      "tab-b": CanvasCardLayout(position: CGPoint(x: 30, y: 40)),
    ])

    let restoredStore = CanvasLayoutStore(defaults: defaults)

    #expect(restoredStore.shouldAutoArrangeOnInitialEntry(for: ["tab-a", "tab-b"]) == false)
    #expect(restoredStore.shouldAutoArrangeOnInitialEntry(for: ["tab-c", "tab-d"]))
  }

  @Test func moveToFrontPersistsZOrder() {
    let defaults = makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let store = CanvasLayoutStore(defaults: defaults)
    store.setCardLayouts(
      [
        "tab-a": CanvasCardLayout(position: .zero),
        "tab-b": CanvasCardLayout(position: .zero),
      ],
      zOrder: ["tab-a", "tab-b"]
    )

    store.moveToFront("tab-a")
    let restoredStore = CanvasLayoutStore(defaults: defaults)

    #expect(restoredStore.zOrder == ["tab-b", "tab-a"])
    #expect(restoredStore.zIndex(for: "tab-a") > restoredStore.zIndex(for: "tab-b"))
  }

  @Test func pruneRemovesStaleLayoutsAndZOrder() {
    let defaults = makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let store = CanvasLayoutStore(defaults: defaults)
    store.setCardLayouts(
      [
        "tab-a": CanvasCardLayout(position: .zero),
        "tab-b": CanvasCardLayout(position: .zero),
      ],
      zOrder: ["tab-a", "tab-b"]
    )

    store.prune(to: ["tab-b"])

    #expect(Array(store.cardLayouts.keys) == ["tab-b"])
    #expect(store.zOrder == ["tab-b"])
  }
}

private enum CanvasLayoutStoreTestLocal {
  @TaskLocal static var marker = 0
}

private func makeDefaults() -> UserDefaults {
  let suiteName = "CanvasLayoutStoreTests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defaults.set(suiteName, forKey: "__suiteName")
  return defaults
}

private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
  defaults.string(forKey: "__suiteName")!
}
