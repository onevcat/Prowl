import Testing

@testable import supacode

struct DiffWindowFocusPolicyTests {
  @Test func showOnNonKeyWindowSwallowsOnlyTheShowFocusEvent() {
    var policy = DiffWindowFocusPolicy()
    policy.noteShow(windowIsKey: false)

    // The focus event produced by makeKeyAndOrderFront itself.
    let showEventRefreshes = policy.shouldRefreshOnBecomeKey()
    // The first genuine refocus after leaving the window must refresh.
    let firstRefocusRefreshes = policy.shouldRefreshOnBecomeKey()

    #expect(!showEventRefreshes)
    #expect(firstRefocusRefreshes)
  }

  @Test func showOnAlreadyKeyWindowDoesNotArmTheSkipFlag() {
    var policy = DiffWindowFocusPolicy()
    policy.noteShow(windowIsKey: false)
    let initialShowRefreshes = policy.shouldRefreshOnBecomeKey()

    // Re-showing while the window is already key emits no focus notification,
    // so arming the flag would swallow the next genuine refocus instead.
    policy.noteShow(windowIsKey: true)
    let refocusRefreshes = policy.shouldRefreshOnBecomeKey()

    #expect(!initialShowRefreshes)
    #expect(refocusRefreshes)
  }

  @Test func repeatedShowsRearmTheFlagOncePerShow() {
    var policy = DiffWindowFocusPolicy()
    policy.noteShow(windowIsKey: false)
    let firstShowRefreshes = policy.shouldRefreshOnBecomeKey()
    let firstRefocusRefreshes = policy.shouldRefreshOnBecomeKey()

    policy.noteShow(windowIsKey: false)
    let secondShowRefreshes = policy.shouldRefreshOnBecomeKey()
    let secondRefocusRefreshes = policy.shouldRefreshOnBecomeKey()

    #expect(!firstShowRefreshes)
    #expect(firstRefocusRefreshes)
    #expect(!secondShowRefreshes)
    #expect(secondRefocusRefreshes)
  }
}
