# tmux Card Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users close a tmux-backed Prowl tab or Canvas card, then restore the same still-running tmux window from the command palette.

**Architecture:** tmux is the source of truth for recoverable cards. Prowl writes raw card metadata to tmux window user options, scans the single global `prowl-cards` container session for live managed windows, filters out windows already visible in the UI, and restores a selected window by creating a new Prowl tab surface that attaches to the existing tmux window. Command palette owns the first-version UI, while `TmuxTerminalController` and `WorktreeTerminalManager` own all tmux identity, scanning, and restore operations.

**Tech Stack:** Swift 6.2, SwiftUI, TCA, GhosttyKit embedded surfaces, tmux 3.6+, Swift Testing, existing `SupaLogger` logging.

---

## Scope

Build the first-version card recovery flow described in `docs/superpowers/specs/2026-05-27-tmux-card-recovery-design.md`.

In scope:

- One Prowl card equals one tmux window equals one Ghostty surface.
- New anonymous tmux tabs are created in the global `prowl-cards` container session.
- Each managed tmux window stores raw `@prowl.*` metadata.
- Closing a tab or Canvas card detaches Prowl UI and keeps the tmux window alive.
- `Kill Terminal` destroys the tmux window.
- `Restore Running Tab` in the command palette opens a detached-card list.
- The detached-card list is computed from live tmux windows at display time.
- Restoring a card creates a new UI tab/card attached to the existing tmux window.
- Diagnostics are surfaced when tmux contains legacy or invalid container structures.

Out of scope:

- Restoring split layout, card position, card size, selection history, or focus history.
- Treating tmux panes as Prowl product concepts.
- Using current directory, session name, or title as identity.
- Using `prowl-tab-*` attach sessions as recovery-list sources.
- Compatibility migration for old `prowl-wt-*` sessions.

## Existing Code Anchors

Anonymous tmux creation currently creates one group session per worktree:

```swift
// supacode/Features/Terminal/Models/TmuxTerminalTarget.swift:93
internal static func make(
  appNamespace: String,
  worktreeID: Worktree.ID,
  tabID: TerminalTabID,
  socketRoot: URL
) -> TmuxTerminalTarget {
  let worktreeHash = stableHash(worktreeID)
  let tabPrefix = tabID.rawValue.uuidString.replacing("-", with: "").prefix(12)
  return TmuxTerminalTarget(
    socketURL: socketRoot.appending(path: "\(appNamespace).sock"),
    groupSession: "\(appNamespace)-wt-\(worktreeHash)",
    clientSession: "\(appNamespace)-tab-\(tabPrefix)",
    windowID: nil,
    paneID: nil
  )
}
```

The new model must change that `groupSession` to the single global container `prowl-cards`.

tmux-backed tab creation currently creates a Prowl tab, then creates a tmux window, then starts Ghostty with an attach command:

```swift
// supacode/Features/Terminal/Models/WorktreeTerminalState.swift:416
let tmuxWorkingDirectory = inherited.workingDirectory ?? worktree.workingDirectory
let title = "\(worktree.name) \(nextTabIndex())"
let tabId = tabManager.createTab(title: title, icon: "terminal", isTitleLocked: false)
var target = TmuxTerminalTarget.make(
  appNamespace: TmuxTabCreation.appNamespace,
  worktreeID: worktree.id,
  tabID: tabId,
  socketRoot: TmuxTabCreation.socketRoot
)
```

Close versus kill semantics already exist and should stay split:

```swift
// supacode/Features/Terminal/Models/WorktreeTerminalState.swift:742
func closeTab(_ tabId: TerminalTabID) {
  let wasRunScriptTab = tabId == runScriptTabId
  removeTree(for: tabId)
  tabManager.closeTab(tabId)
  if let selected = tabManager.selectedTabId {
    focusSurface(in: selected)
  } else {
    lastEmittedFocusSurfaceId = nil
  }
  emitTaskStatusIfChanged()
  if wasRunScriptTab {
    setRunScriptTabId(nil)
  }
  onTabClosed?()
}
```

```swift
// supacode/Features/Terminal/Models/WorktreeTerminalState.swift:678
func killFocusedTab() async -> Bool {
  guard let tabId = tabManager.selectedTabId else { return false }
  if let target = tmuxTargetsByTabId[tabId], let tmuxController {
    try? await tmuxController.killWindow(target: target)
    tmuxTargetsByTabId[tabId] = nil
  }
  closeTab(tabId)
  return true
}
```

Canvas already derives display strings from live surface state:

```swift
// supacode/Features/Canvas/Views/CanvasView.swift:304
let currentDirectoryPath = state.surfaceView(for: tab.id)?.bridge.state.pwd
  ?? state.repositoryRootURL.path(percentEncoded: false)
let titleSegments = canvasCardTitleSegments(
  currentDirectoryPath: currentDirectoryPath,
  tabTitle: tab.displayTitle,
  cachedDirectoryEntry: directoryDisplayCache[tab.id]
)
```

The recovery flow should use the same presentation rules from raw tmux runtime fields, not write derived UI strings to tmux.

## File Structure

- Modify `supacode/Features/Terminal/Models/TmuxTerminalTarget.swift`
  - Add global container naming, stable card ID, and target construction for restored windows.
- Create `supacode/Features/Terminal/Models/TmuxCardRecovery.swift`
  - Value types for raw tmux records, metadata, detached candidates, diagnostics, and the command-palette snapshot.
- Modify `supacode/Features/Terminal/BusinessLogic/TmuxTerminalController.swift`
  - Write tmux user options on creation, scan live managed windows, detect legacy structures, validate a window before restore, and rebuild attach sessions for restored windows.
- Modify `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`
  - Pass metadata during creation, expose visible tmux window IDs, restore an existing tmux window into a new UI tab, and keep close/kill semantics intact.
- Modify `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
  - Aggregate visible tmux windows, resolve detached candidates against app worktrees, and expose scan/restore methods to `TerminalClient`.
- Modify `supacode/Clients/Terminal/TerminalClient.swift`
  - Add async scan and restore closures for command-palette flow.
- Modify `supacode/App/supacodeApp.swift`
  - Wire the new `TerminalClient` closures to `WorktreeTerminalManager`.
- Modify `supacode/Features/CommandPalette/CommandPaletteItem.swift`
  - Add `Restore Running Tab` and detached-card row item kinds.
- Modify `supacode/Features/CommandPalette/Reducer/CommandPaletteFeature.swift`
  - Add a detached-card selection mode, loading/result actions, and delegates.
- Modify `supacode/Features/CommandPalette/Views/CommandPaletteOverlayView.swift`
  - Render the detached-card list, diagnostics, and empty state.
- Modify `supacode/Features/App/Reducer/AppFeature.swift`
  - Handle command-palette delegates by scanning tmux, entering detached-card mode, and restoring selected candidates.
- Add tests:
  - `supacodeTests/TmuxCardRecoveryTests.swift`
  - Extend `supacodeTests/TmuxTerminalTargetTests.swift`
  - Extend `supacodeTests/TmuxTerminalControllerTests.swift`
  - Extend `supacodeTests/WorktreeTerminalManagerTests.swift`
  - Extend `supacodeTests/CommandPaletteFeatureTests.swift`
  - Extend `supacodeTests/AppFeatureCommandPaletteTests.swift`

The Xcode project uses file-system synchronized groups for `supacode` and `supacodeTests`, so new Swift files in those folders should be picked up without editing `supacode.xcodeproj/project.pbxproj`.

### Task 1: Switch tmux Target Identity to a Global Card Container

**Files:**
- Modify: `supacode/Features/Terminal/Models/TmuxTerminalTarget.swift:86-114`
- Modify: `supacodeTests/TmuxTerminalTargetTests.swift:6-48`

- [ ] **Step 1: Write target naming tests**

Replace the existing first test in `supacodeTests/TmuxTerminalTargetTests.swift` with this focused expectation:

```swift
@Test internal func targetUsesGlobalCardContainerAndStableCardID() throws {
  let tabID = TerminalTabID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
  let cardID = TmuxCardID(rawValue: "card-111111111111")

  let target = TmuxTerminalTarget.make(
    appNamespace: "prowl",
    worktreeID: "/Users/yam/Developer/Prowl",
    tabID: tabID,
    cardID: cardID,
    socketRoot: URL(fileURLWithPath: "/tmp/prowl-tmux", isDirectory: true)
  )

  #expect(target.groupSession == "prowl-cards")
  #expect(target.clientSession == "prowl-tab-111111111111")
  #expect(target.cardID == cardID)
  #expect(target.socketURL.path == "/tmp/prowl-tmux/prowl.sock")
}
```

Add a restored-target test:

```swift
@Test internal func restoredTargetKeepsWindowCardIDAndUsesNewClientSession() throws {
  let tabID = TerminalTabID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
  let target = TmuxTerminalTarget.restored(
    socketURL: URL(fileURLWithPath: "/tmp/prowl-tmux/prowl.sock", isDirectory: false),
    tabID: tabID,
    cardID: TmuxCardID(rawValue: "card-original"),
    windowID: TmuxWindowID(rawValue: "@21"),
    paneID: TmuxPaneID(rawValue: "%9")
  )

  #expect(target.groupSession == "prowl-cards")
  #expect(target.clientSession == "prowl-tab-222222222222")
  #expect(target.cardID.rawValue == "card-original")
  #expect(target.windowID?.rawValue == "@21")
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxTerminalTargetTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because `TmuxCardID`, the `cardID` parameter, and `restored(...)` do not exist.

- [ ] **Step 3: Implement target identity**

Add `TmuxCardID` near the other tmux ID value types:

```swift
internal struct TmuxCardID: Codable, Equatable, Hashable, Sendable {
  internal let rawValue: String

  internal init(rawValue: String) {
    self.rawValue = rawValue
  }
}
```

Update `TmuxTerminalTarget` with a card ID and fixed container:

```swift
internal struct TmuxTerminalTarget: Codable, Equatable, Hashable, Sendable {
  internal static let cardContainerSession = "prowl-cards"

  internal let socketURL: URL
  internal let groupSession: String
  internal let clientSession: String
  internal let cardID: TmuxCardID
  internal var windowID: TmuxWindowID?
  internal var paneID: TmuxPaneID?
```

Replace `make(...)` with this key body:

```swift
internal static func make(
  appNamespace: String,
  worktreeID _: Worktree.ID,
  tabID: TerminalTabID,
  cardID: TmuxCardID,
  socketRoot: URL
) -> TmuxTerminalTarget {
  let tabPrefix = tabID.rawValue.uuidString.replacing("-", with: "").prefix(12)
  return TmuxTerminalTarget(
    socketURL: socketRoot.appending(path: "\(appNamespace).sock"),
    groupSession: cardContainerSession,
    clientSession: "\(appNamespace)-tab-\(tabPrefix)",
    cardID: cardID,
    windowID: nil,
    paneID: nil
  )
}
```

Add restored-target construction:

```swift
internal static func restored(
  socketURL: URL,
  tabID: TerminalTabID,
  cardID: TmuxCardID,
  windowID: TmuxWindowID,
  paneID: TmuxPaneID?
) -> TmuxTerminalTarget {
  let tabPrefix = tabID.rawValue.uuidString.replacing("-", with: "").prefix(12)
  return TmuxTerminalTarget(
    socketURL: socketURL,
    groupSession: cardContainerSession,
    clientSession: "prowl-tab-\(tabPrefix)",
    cardID: cardID,
    windowID: windowID,
    paneID: paneID
  )
}
```

Fix existing target initializers in tests by adding `cardID: TmuxCardID(rawValue: "card-test")`.

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxTerminalTargetTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add supacode/Features/Terminal/Models/TmuxTerminalTarget.swift supacodeTests/TmuxTerminalTargetTests.swift
git commit -m "refactor(terminal): use global tmux card container"
```

### Task 2: Add Raw Recovery Value Types

**Files:**
- Create: `supacode/Features/Terminal/Models/TmuxCardRecovery.swift`
- Create: `supacodeTests/TmuxCardRecoveryTests.swift`

- [ ] **Step 1: Write value-type tests**

Create `supacodeTests/TmuxCardRecoveryTests.swift`:

```swift
import Foundation
import Testing

@testable import supacode

internal struct TmuxCardRecoveryTests {
  @Test internal func rawRecordBuildsManagedCandidateWithRuntimeFallbackTitle() throws {
    let record = TmuxRawWindowRecord(
      sessionName: "prowl-cards",
      windowID: "@21",
      windowName: "shell",
      activePath: "/Users/yam/Developer/Prowl",
      activeCommand: "zsh",
      activeTitle: "",
      managed: "1",
      cardID: "card-21",
      worktreeID: "/Users/yam/Developer/Prowl/.worktrees/feature",
      worktreePath: "/Users/yam/Developer/Prowl/.worktrees/feature",
      repositoryRoot: "/Users/yam/Developer/Prowl",
      createdAt: "2026-05-28T12:00:00Z"
    )

    let candidate = try #require(TmuxDetachedCardCandidate(record: record))

    #expect(candidate.id.rawValue == "prowl.sock:@21")
    #expect(candidate.windowID.rawValue == "@21")
    #expect(candidate.cardID.rawValue == "card-21")
    #expect(candidate.runtimeTitle == "shell")
    #expect(candidate.activePath == "/Users/yam/Developer/Prowl")
  }

  @Test internal func rawRecordRejectsUnmanagedBootstrapAndInvalidWindowIDs() {
    let unmanaged = TmuxRawWindowRecord(
      sessionName: "prowl-cards",
      windowID: "@21",
      windowName: "shell",
      activePath: "/tmp",
      activeCommand: "zsh",
      activeTitle: "zsh",
      managed: "0",
      cardID: "card-21",
      worktreeID: "/tmp/wt",
      worktreePath: "/tmp/wt",
      repositoryRoot: "/tmp",
      createdAt: "2026-05-28T12:00:00Z"
    )
    let bootstrap = TmuxRawWindowRecord(
      sessionName: "prowl-cards",
      windowID: "@22",
      windowName: "__prowl_bootstrap",
      activePath: "/tmp",
      activeCommand: "zsh",
      activeTitle: "zsh",
      managed: "1",
      cardID: "card-22",
      worktreeID: "/tmp/wt",
      worktreePath: "/tmp/wt",
      repositoryRoot: "/tmp",
      createdAt: "2026-05-28T12:00:00Z"
    )
    let invalidID = TmuxRawWindowRecord(
      sessionName: "prowl-cards",
      windowID: "%22",
      windowName: "shell",
      activePath: "/tmp",
      activeCommand: "zsh",
      activeTitle: "zsh",
      managed: "1",
      cardID: "card-22",
      worktreeID: "/tmp/wt",
      worktreePath: "/tmp/wt",
      repositoryRoot: "/tmp",
      createdAt: "2026-05-28T12:00:00Z"
    )

    #expect(TmuxDetachedCardCandidate(record: unmanaged) == nil)
    #expect(TmuxDetachedCardCandidate(record: bootstrap) == nil)
    #expect(TmuxDetachedCardCandidate(record: invalidID) == nil)
  }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxCardRecoveryTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because the recovery value types do not exist.

- [ ] **Step 3: Implement recovery models**

Create `supacode/Features/Terminal/Models/TmuxCardRecovery.swift`:

```swift
import Foundation

internal nonisolated struct TmuxRawWindowRecord: Equatable, Sendable {
  internal let sessionName: String
  internal let windowID: String
  internal let windowName: String
  internal let activePath: String
  internal let activeCommand: String
  internal let activeTitle: String
  internal let managed: String
  internal let cardID: String
  internal let worktreeID: String
  internal let worktreePath: String
  internal let repositoryRoot: String
  internal let createdAt: String
}

internal nonisolated struct TmuxDetachedCardCandidate: Equatable, Identifiable, Sendable {
  internal struct ID: RawRepresentable, Equatable, Hashable, Sendable {
    internal let rawValue: String
    internal init(rawValue: String) { self.rawValue = rawValue }
  }

  internal let id: ID
  internal let sessionName: String
  internal let windowID: TmuxWindowID
  internal let cardID: TmuxCardID
  internal let worktreeID: Worktree.ID
  internal let worktreePath: String
  internal let repositoryRoot: String
  internal let activePath: String?
  internal let activeCommand: String?
  internal let activeTitle: String?
  internal let windowName: String?
  internal let createdAt: String?

  internal init?(record: TmuxRawWindowRecord, socketName: String = "prowl.sock") {
    guard record.sessionName == TmuxTerminalTarget.cardContainerSession else { return nil }
    guard record.managed == "1" else { return nil }
    guard record.windowName != "__prowl_bootstrap" else { return nil }
    guard let windowID = TmuxWindowID(rawValue: record.windowID) else { return nil }
    let cardID = record.cardID.trimmedNonEmpty.map(TmuxCardID.init(rawValue:))
      ?? TmuxCardID(rawValue: windowID.rawValue)
    guard let worktreeID = record.worktreeID.trimmedNonEmpty else { return nil }
    guard let worktreePath = record.worktreePath.trimmedNonEmpty else { return nil }
    guard let repositoryRoot = record.repositoryRoot.trimmedNonEmpty else { return nil }

    self.id = ID(rawValue: "\(socketName):\(windowID.rawValue)")
    self.sessionName = record.sessionName
    self.windowID = windowID
    self.cardID = cardID
    self.worktreeID = worktreeID
    self.worktreePath = worktreePath
    self.repositoryRoot = repositoryRoot
    self.activePath = record.activePath.trimmedNonEmpty
    self.activeCommand = record.activeCommand.trimmedNonEmpty
    self.activeTitle = record.activeTitle.trimmedNonEmpty
    self.windowName = record.windowName.trimmedNonEmpty
    self.createdAt = record.createdAt.trimmedNonEmpty
  }

  internal var runtimeTitle: String? {
    activeTitle ?? windowName ?? activeCommand
  }
}

internal nonisolated struct TmuxCardStructureDiagnostic: Equatable, Sendable {
  internal let message: String
  internal let socketPath: String
  internal let sessionNames: [String]
  internal let windowCountsBySession: [String: Int]
}

internal nonisolated struct TmuxCardRecoverySnapshot: Equatable, Sendable {
  internal let candidates: [TmuxDetachedCardCandidate]
  internal let diagnostics: [TmuxCardStructureDiagnostic]
}

private extension String {
  var trimmedNonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxCardRecoveryTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add supacode/Features/Terminal/Models/TmuxCardRecovery.swift supacodeTests/TmuxCardRecoveryTests.swift
git commit -m "feat(terminal): model tmux card recovery records"
```

### Task 3: Write tmux Window Metadata at Creation Time

**Files:**
- Modify: `supacode/Features/Terminal/BusinessLogic/TmuxTerminalController.swift:79-105`
- Modify: `supacode/Features/Terminal/Models/WorktreeTerminalState.swift:406-469`
- Modify: `supacodeTests/TmuxTerminalControllerTests.swift:1-93`
- Modify: `supacodeTests/WorktreeTerminalManagerTests.swift:168-194`

- [ ] **Step 1: Write controller metadata test**

Add this test to `TmuxTerminalControllerTests`:

```swift
@Test internal func createWindowWritesProwlMetadataToWindowOptions() async throws {
  let recorder = TmuxCommandRecorder()
  let controller = TmuxTerminalController(
    executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
    execute: { _, arguments in
      await recorder.record(arguments)
      if arguments.contains("new-window") {
        return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
      }
      return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
    }
  )
  let target = TmuxTerminalTarget.make(
    appNamespace: "prowl",
    worktreeID: "/tmp/repo/wt",
    tabID: TerminalTabID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
    cardID: TmuxCardID(rawValue: "card-7"),
    socketRoot: URL(fileURLWithPath: "/tmp/prowl-tmux", isDirectory: true)
  )
  let metadata = TmuxWindowMetadata(
    cardID: target.cardID,
    worktreeID: "/tmp/repo/wt",
    worktreePath: "/tmp/repo/wt",
    repositoryRoot: "/tmp/repo",
    createdAt: "2026-05-28T12:00:00Z"
  )

  _ = try await controller.createWindow(
    target: target,
    cwd: URL(fileURLWithPath: "/tmp/repo/wt", isDirectory: true),
    title: "wt 1",
    metadata: metadata
  )

  let arguments = await recorder.arguments
  #expect(arguments.contains { $0 == ["-S", "/tmp/prowl-tmux/prowl.sock", "set-window-option", "-t", "@7", "@prowl.managed", "1"] })
  #expect(arguments.contains { $0 == ["-S", "/tmp/prowl-tmux/prowl.sock", "set-window-option", "-t", "@7", "@prowl.card_id", "card-7"] })
  #expect(arguments.contains { $0 == ["-S", "/tmp/prowl-tmux/prowl.sock", "set-window-option", "-t", "@7", "@prowl.worktree_id", "/tmp/repo/wt"] })
  #expect(arguments.contains { $0 == ["-S", "/tmp/prowl-tmux/prowl.sock", "set-window-option", "-t", "@7", "@prowl.repository_root", "/tmp/repo"] })
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxTerminalControllerTests/createWindowWritesProwlMetadataToWindowOptions \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because `TmuxWindowMetadata` and the `metadata:` parameter do not exist.

- [ ] **Step 3: Add metadata model**

Add this to `TmuxCardRecovery.swift`:

```swift
internal nonisolated struct TmuxWindowMetadata: Equatable, Sendable {
  internal let cardID: TmuxCardID
  internal let worktreeID: Worktree.ID
  internal let worktreePath: String
  internal let repositoryRoot: String
  internal let createdAt: String
}
```

- [ ] **Step 4: Write metadata in the controller**

Change the `createWindow` signature in `TmuxTerminalController.swift`:

```swift
internal func createWindow(
  target: TmuxTerminalTarget,
  cwd: URL,
  title: String,
  metadata: TmuxWindowMetadata
) async throws -> TmuxTerminalTarget {
```

After parsing `windowID` and `paneID`, write user options before `ensureClientSession`:

```swift
updated.windowID = windowID
updated.paneID = paneID
try await setWindowMetadata(metadata, windowID: windowID, socketURL: target.socketURL)
try await ensureClientSession(target: updated)
return updated
```

Add the private helper:

```swift
private func setWindowMetadata(
  _ metadata: TmuxWindowMetadata,
  windowID: TmuxWindowID,
  socketURL: URL
) async throws {
  let options: [(String, String)] = [
    ("@prowl.managed", "1"),
    ("@prowl.card_id", metadata.cardID.rawValue),
    ("@prowl.worktree_id", metadata.worktreeID),
    ("@prowl.worktree_path", metadata.worktreePath),
    ("@prowl.repository_root", metadata.repositoryRoot),
    ("@prowl.created_at", metadata.createdAt),
  ]
  for (name, value) in options {
    _ = try await run([
      "-S", socketURL.path,
      "set-window-option",
      "-t", windowID.rawValue,
      name, value,
    ])
  }
}
```

- [ ] **Step 5: Pass metadata from tab creation**

In `WorktreeTerminalState.createTabAsync`, create a card ID and metadata before `TmuxTerminalTarget.make(...)`:

```swift
let cardID = TmuxCardID(rawValue: tabId.rawValue.uuidString)
let createdAt = ISO8601DateFormatter().string(from: Date())
let metadata = TmuxWindowMetadata(
  cardID: cardID,
  worktreeID: worktree.id,
  worktreePath: tmuxWorkingDirectory.path(percentEncoded: false),
  repositoryRoot: worktree.repositoryRootURL.path(percentEncoded: false),
  createdAt: createdAt
)
var target = TmuxTerminalTarget.make(
  appNamespace: TmuxTabCreation.appNamespace,
  worktreeID: worktree.id,
  tabID: tabId,
  cardID: cardID,
  socketRoot: TmuxTabCreation.socketRoot
)
```

Pass the metadata to `createWindow`:

```swift
target = try await tmuxController.createWindow(
  target: target,
  cwd: tmuxWorkingDirectory,
  title: title,
  metadata: metadata
)
```

- [ ] **Step 6: Fix existing test initializers**

Update existing `TmuxTerminalTarget(...)` test literals with `cardID`:

```swift
TmuxTerminalTarget(
  socketURL: URL(fileURLWithPath: "/tmp/prowl.sock", isDirectory: false),
  groupSession: TmuxTerminalTarget.cardContainerSession,
  clientSession: "prowl-tab-test",
  cardID: TmuxCardID(rawValue: "card-test"),
  windowID: TmuxWindowID(rawValue: "@42"),
  paneID: nil
)
```

- [ ] **Step 7: Run focused tests**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxTerminalControllerTests \
  -only-testing:supacodeTests/WorktreeTerminalManagerTests/tmuxBackedTabUsesAttachCommand \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add supacode/Features/Terminal/BusinessLogic/TmuxTerminalController.swift supacode/Features/Terminal/Models/WorktreeTerminalState.swift supacode/Features/Terminal/Models/TmuxCardRecovery.swift supacodeTests/TmuxTerminalControllerTests.swift supacodeTests/WorktreeTerminalManagerTests.swift
git commit -m "feat(terminal): write tmux card metadata"
```

### Task 4: Scan Live tmux Windows for Detached Cards

**Files:**
- Modify: `supacode/Features/Terminal/BusinessLogic/TmuxTerminalController.swift:20-237`
- Modify: `supacode/Features/Terminal/Models/WorktreeTerminalState.swift:169-175`
- Modify: `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift:24-82`
- Modify: `supacodeTests/TmuxTerminalControllerTests.swift:1-132`
- Modify: `supacodeTests/WorktreeTerminalManagerTests.swift:168-430`

- [ ] **Step 1: Write controller scan tests**

Add this test to `TmuxTerminalControllerTests`:

```swift
@Test internal func detachedCardScanFiltersVisibleWindowsAndReportsLegacyContainers() async throws {
  let controller = TmuxTerminalController(
    executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
    execute: { _, arguments in
      if arguments.contains("list-sessions") {
        return TmuxCommandResult(
          stdout: "prowl-cards\u{1F}2\nprowl-wt-old\u{1F}1\n",
          stderr: "",
          exitCode: 0
        )
      }
      if arguments.contains("list-windows") {
        return TmuxCommandResult(
          stdout: [
            "prowl-cards\u{1F}@21\u{1F}shell\u{1F}/tmp/repo/wt\u{1F}zsh\u{1F}\u{1F}1\u{1F}card-21\u{1F}/tmp/repo/wt\u{1F}/tmp/repo/wt\u{1F}/tmp/repo\u{1F}2026-05-28T12:00:00Z",
            "prowl-cards\u{1F}@22\u{1F}visible\u{1F}/tmp/repo/wt\u{1F}zsh\u{1F}\u{1F}1\u{1F}card-22\u{1F}/tmp/repo/wt\u{1F}/tmp/repo/wt\u{1F}/tmp/repo\u{1F}2026-05-28T12:00:00Z",
          ].joined(separator: "\n"),
          stderr: "",
          exitCode: 0
        )
      }
      return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
    }
  )

  let snapshot = try await controller.detachedCardSnapshot(
    visibleWindowIDs: [TmuxWindowID(rawValue: "@22")!]
  )

  #expect(snapshot.candidates.map(\.windowID.rawValue) == ["@21"])
  #expect(snapshot.diagnostics.count == 1)
  #expect(snapshot.diagnostics.first?.sessionNames == ["prowl-cards", "prowl-wt-old"])
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxTerminalControllerTests/detachedCardScanFiltersVisibleWindowsAndReportsLegacyContainers \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because `detachedCardSnapshot(visibleWindowIDs:)` does not exist.

- [ ] **Step 3: Implement scan format and parsing**

Add constants to `TmuxTerminalController`:

```swift
private enum TmuxRecoveryScan {
  static let separator = "\u{1F}"
  static let sessionFormat = "#{session_name}\(separator)#{session_windows}"
  static let windowFormat = [
    "#{session_name}",
    "#{window_id}",
    "#{window_name}",
    "#{pane_current_path}",
    "#{pane_current_command}",
    "#{pane_title}",
    "#{@prowl.managed}",
    "#{@prowl.card_id}",
    "#{@prowl.worktree_id}",
    "#{@prowl.worktree_path}",
    "#{@prowl.repository_root}",
    "#{@prowl.created_at}",
  ].joined(separator: separator)
}
```

Add the scan entrypoint:

```swift
internal func detachedCardSnapshot(
  visibleWindowIDs: Set<TmuxWindowID>
) async throws -> TmuxCardRecoverySnapshot {
  let sessions = try await listSessions()
  let diagnostics = structureDiagnostics(from: sessions)
  guard sessions.contains(where: { $0.name == TmuxTerminalTarget.cardContainerSession }) else {
    return TmuxCardRecoverySnapshot(candidates: [], diagnostics: diagnostics)
  }

  let records = try await listRawWindowRecords()
  let visibleIDs = Set(visibleWindowIDs.map(\.rawValue))
  let candidates = records
    .compactMap(TmuxDetachedCardCandidate.init(record:))
    .filter { !visibleIDs.contains($0.windowID.rawValue) }
    .sorted { left, right in
      if left.createdAt != right.createdAt {
        return (left.createdAt ?? "") > (right.createdAt ?? "")
      }
      return left.windowID.rawValue < right.windowID.rawValue
    }
  return TmuxCardRecoverySnapshot(candidates: candidates, diagnostics: diagnostics)
}
```

Add session and window parsing:

```swift
private struct TmuxSessionRecord: Equatable {
  let name: String
  let windowCount: Int
}

private func listSessions() async throws -> [TmuxSessionRecord] {
  guard let socketURL = defaultSocketURL else { return [] }
  let result = try await run(
    ["-S", socketURL.path, "list-sessions", "-F", TmuxRecoveryScan.sessionFormat],
    allowFailure: true
  )
  guard result.exitCode == 0 else { return [] }
  return result.stdout.split(separator: "\n").compactMap { line in
    let fields = line.split(separator: Character(TmuxRecoveryScan.separator), omittingEmptySubsequences: false)
    guard fields.count == 2, let count = Int(fields[1]) else { return nil }
    return TmuxSessionRecord(name: String(fields[0]), windowCount: count)
  }
}

private func listRawWindowRecords() async throws -> [TmuxRawWindowRecord] {
  guard let socketURL = defaultSocketURL else { return [] }
  let result = try await run([
    "-S", socketURL.path,
    "list-windows",
    "-t", TmuxTerminalTarget.cardContainerSession,
    "-F", TmuxRecoveryScan.windowFormat,
  ])
  return result.stdout.split(separator: "\n").compactMap(parseRawWindowRecord)
}
```

Add `defaultSocketURL` near `isAvailable`:

```swift
internal var defaultSocketURL: URL? {
  guard isAvailable else { return nil }
  return SupacodePaths.cacheDirectory
    .appending(path: "tmux", directoryHint: .isDirectory)
    .appending(path: "prowl.sock")
}
```

Add raw record parsing:

```swift
private func parseRawWindowRecord(_ line: Substring) -> TmuxRawWindowRecord? {
  let fields = line.split(separator: Character(TmuxRecoveryScan.separator), omittingEmptySubsequences: false)
  guard fields.count == 12 else { return nil }
  return TmuxRawWindowRecord(
    sessionName: String(fields[0]),
    windowID: String(fields[1]),
    windowName: String(fields[2]),
    activePath: String(fields[3]),
    activeCommand: String(fields[4]),
    activeTitle: String(fields[5]),
    managed: String(fields[6]),
    cardID: String(fields[7]),
    worktreeID: String(fields[8]),
    worktreePath: String(fields[9]),
    repositoryRoot: String(fields[10]),
    createdAt: String(fields[11])
  )
}
```

Add diagnostics:

```swift
private func structureDiagnostics(from sessions: [TmuxSessionRecord]) -> [TmuxCardStructureDiagnostic] {
  let anomalous = sessions.filter { session in
    session.name.hasPrefix("prowl-wt-")
      || (session.name.hasPrefix("prowl-") && session.name != TmuxTerminalTarget.cardContainerSession)
  }
  guard !anomalous.isEmpty, let socketPath = defaultSocketURL?.path else { return [] }
  let allNames = sessions.map(\.name).sorted()
  let counts = Dictionary(uniqueKeysWithValues: sessions.map { ($0.name, $0.windowCount) })
  logger.warning(
    "tmux recovery found unexpected sessions socket=\(socketPath) sessions=\(allNames) windowCounts=\(counts)"
  )
  return [
    TmuxCardStructureDiagnostic(
      message: "Unexpected tmux sessions found. Restore will show safe managed cards only.",
      socketPath: socketPath,
      sessionNames: allNames,
      windowCountsBySession: counts
    )
  ]
}
```

- [ ] **Step 4: Expose visible window IDs**

Add to `WorktreeTerminalState`:

```swift
func visibleTmuxWindowIDs() -> Set<TmuxWindowID> {
  Set(tmuxTargetsByTabId.values.compactMap(\.windowID))
}
```

Add to `WorktreeTerminalManager`:

```swift
func visibleTmuxWindowIDs() -> Set<TmuxWindowID> {
  states.values.reduce(into: Set<TmuxWindowID>()) { result, state in
    result.formUnion(state.visibleTmuxWindowIDs())
  }
}

func detachedTmuxCardSnapshot() async -> TmuxCardRecoverySnapshot {
  guard let tmuxController, tmuxController.isAvailable else {
    return TmuxCardRecoverySnapshot(candidates: [], diagnostics: [])
  }
  do {
    return try await tmuxController.detachedCardSnapshot(visibleWindowIDs: visibleTmuxWindowIDs())
  } catch {
    terminalLogger.warning("tmux recovery scan failed: \(error)")
    return TmuxCardRecoverySnapshot(candidates: [], diagnostics: [])
  }
}
```

- [ ] **Step 5: Run focused scan tests**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxTerminalControllerTests/detachedCardScanFiltersVisibleWindowsAndReportsLegacyContainers \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add supacode/Features/Terminal/BusinessLogic/TmuxTerminalController.swift supacode/Features/Terminal/Models/WorktreeTerminalState.swift supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift supacodeTests/TmuxTerminalControllerTests.swift
git commit -m "feat(terminal): scan detached tmux cards"
```

### Task 5: Restore an Existing tmux Window into a New Prowl Tab

**Files:**
- Modify: `supacode/Features/Terminal/BusinessLogic/TmuxTerminalController.swift:107-171`
- Modify: `supacode/Features/Terminal/Models/WorktreeTerminalState.swift:376-477`
- Modify: `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift:254-360`
- Modify: `supacodeTests/TmuxTerminalControllerTests.swift:1-132`
- Modify: `supacodeTests/WorktreeTerminalManagerTests.swift:168-430`

- [ ] **Step 1: Write controller restore validation test**

Add this test:

```swift
@Test internal func prepareExistingWindowSelectsWindowInFreshAttachSession() async throws {
  let recorder = TmuxCommandRecorder()
  let controller = TmuxTerminalController(
    executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
    execute: { _, arguments in
      await recorder.record(arguments)
      if arguments.contains("display-message") {
        return TmuxCommandResult(stdout: "@21\n", stderr: "", exitCode: 0)
      }
      return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
    }
  )
  let target = TmuxTerminalTarget.restored(
    socketURL: URL(fileURLWithPath: "/tmp/prowl.sock", isDirectory: false),
    tabID: TerminalTabID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
    cardID: TmuxCardID(rawValue: "card-21"),
    windowID: TmuxWindowID(rawValue: "@21")!,
    paneID: nil
  )

  let prepared = try await controller.prepareExistingWindowForAttach(target: target)

  let arguments = await recorder.arguments
  #expect(prepared == target)
  #expect(arguments.contains { $0.contains("display-message") && $0.contains("@21") })
  #expect(arguments.contains { $0.contains("new-session") && $0.contains("prowl-tab-222222222222") })
  #expect(arguments.contains { $0.contains("select-window") && $0.contains("prowl-tab-222222222222:@21") })
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxTerminalControllerTests/prepareExistingWindowSelectsWindowInFreshAttachSession \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because `prepareExistingWindowForAttach` does not exist.

- [ ] **Step 3: Add controller restore preparation**

Add to `TmuxTerminalController`:

```swift
internal func prepareExistingWindowForAttach(target: TmuxTerminalTarget) async throws -> TmuxTerminalTarget {
  guard let windowID = target.windowID else {
    throw TmuxTerminalControllerError.invalidNewWindowOutput("missing restore window id")
  }
  let result = try await run(
    [
      "-S", target.socketURL.path,
      "display-message",
      "-p",
      "-t", windowID.rawValue,
      "#{window_id}",
    ],
    allowFailure: true
  )
  guard result.exitCode == 0, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == windowID.rawValue else {
    throw TmuxTerminalControllerError.commandFailed(
      arguments: ["display-message", "-t", windowID.rawValue],
      stderr: result.stderr,
      exitCode: result.exitCode
    )
  }
  try await ensureClientSession(target: target)
  return target
}
```

- [ ] **Step 4: Write manager restore test**

Add this test to `WorktreeTerminalManagerTests`:

```swift
@Test func restoresDetachedCardByAttachingExistingWindow() async throws {
  let recorder = TmuxCommandRecorder()
  let controller = TmuxTerminalController(
    executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
    execute: { _, arguments in
      await recorder.record(arguments)
      if arguments.contains("list-sessions") {
        return TmuxCommandResult(stdout: "prowl-cards\u{1F}1\n", stderr: "", exitCode: 0)
      }
      if arguments.contains("list-windows") {
        return TmuxCommandResult(
          stdout: "prowl-cards\u{1F}@21\u{1F}shell\u{1F}/tmp/repo/wt\u{1F}zsh\u{1F}codex\u{1F}1\u{1F}card-21\u{1F}/tmp/repo/wt\u{1F}/tmp/repo/wt\u{1F}/tmp/repo\u{1F}2026-05-28T12:00:00Z",
          stderr: "",
          exitCode: 0
        )
      }
      if arguments.contains("display-message") {
        return TmuxCommandResult(stdout: "@21\n", stderr: "", exitCode: 0)
      }
      return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
    }
  )
  let manager = WorktreeTerminalManager(
    runtime: GhosttyRuntime(),
    tmuxController: controller,
    usesAnonymousTmux: true
  )
  let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt", repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"))

  let snapshot = await manager.detachedTmuxCardSnapshot()
  let candidateID = try #require(snapshot.candidates.first?.id)
  let restored = await manager.restoreDetachedTmuxCard(candidateID, worktrees: [worktree])

  let state = try #require(manager.stateIfExists(for: worktree.id))
  let restoredTab = try #require(state.tabManager.selectedTabId)
  let surface = try #require(state.surfaceView(for: restoredTab))

  #expect(restored == true)
  #expect(state.tmuxTargetForTesting(restoredTab)?.windowID?.rawValue == "@21")
  #expect(state.tmuxTargetForTesting(restoredTab)?.cardID.rawValue == "card-21")
  #expect(surface.launchCommandForTesting?.contains("-CC attach-session") == true)
}
```

- [ ] **Step 5: Run manager restore test to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/WorktreeTerminalManagerTests/restoresDetachedCardByAttachingExistingWindow \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because manager and state restore methods do not exist.

- [ ] **Step 6: Add state restore method**

Add to `WorktreeTerminalState`:

```swift
@discardableResult
func restoreDetachedTmuxCard(_ candidate: TmuxDetachedCardCandidate) async -> TerminalTabID? {
  guard let tmuxController, tmuxController.isAvailable else { return nil }
  let tabID = TerminalTabID(rawValue: UUID())
  let target = TmuxTerminalTarget.restored(
    socketURL: TmuxTabCreation.socketRoot.appending(path: "\(TmuxTabCreation.appNamespace).sock"),
    tabID: tabID,
    cardID: candidate.cardID,
    windowID: candidate.windowID,
    paneID: nil
  )
  do {
    let preparedTarget = try await tmuxController.prepareExistingWindowForAttach(target: target)
    let title = candidate.runtimeTitle ?? worktree.name
    let createdTabID = tabManager.createTab(title: title, icon: "terminal", isTitleLocked: false)
    guard createdTabID == tabID else {
      terminalStateLogger.warning("tmux restore tab id drifted expected=\(tabID) actual=\(createdTabID)")
      return nil
    }
    let tree = splitTree(
      for: tabID,
      initialInput: nil,
      workingDirectoryOverride: URL(fileURLWithPath: candidate.activePath ?? candidate.worktreePath, isDirectory: true),
      launchCommandOverride: tmuxController.attachCommand(for: preparedTarget),
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    tmuxTargetsByTabId[tabID] = preparedTarget
    tabIsRunningById[tabID] = false
    tabManager.selectTab(tabID)
    if let surface = tree.root?.leftmostLeaf() {
      focusSurface(surface, in: tabID)
      onFocusedCommandSurfaceCreated?(surface.id)
    }
    onTabCreated?()
    return tabID
  } catch {
    terminalStateLogger.warning("tmux restore failed window=\(candidate.windowID.rawValue) card=\(candidate.cardID.rawValue): \(error)")
    return nil
  }
}
```

If `TerminalTabManager.createTab` does not allow injecting a tab ID, add a focused overload in `TerminalTabManager` first:

```swift
func createTab(
  id: TerminalTabID = TerminalTabID(rawValue: UUID()),
  title: String,
  icon: String?,
  isTitleLocked: Bool = false
) -> TerminalTabID {
  let tab = TerminalTabItem(id: id, title: title, icon: icon, isTitleLocked: isTitleLocked)
  if let selectedTabId,
    let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabId })
  {
    tabs.insert(tab, at: selectedIndex + 1)
  } else {
    tabs.append(tab)
  }
  selectedTabId = tab.id
  return tab.id
}
```

Then use `tabManager.createTab(id: tabID, title: title, icon: "terminal", isTitleLocked: false)` in the restore method.

- [ ] **Step 7: Add manager restore method**

Add to `WorktreeTerminalManager`:

```swift
func restoreDetachedTmuxCard(
  _ candidateID: TmuxDetachedCardCandidate.ID,
  worktrees: [Worktree]
) async -> Bool {
  let snapshot = await detachedTmuxCardSnapshot()
  guard let candidate = snapshot.candidates.first(where: { $0.id == candidateID }) else {
    terminalLogger.warning("tmux restore candidate vanished id=\(candidateID.rawValue)")
    return false
  }
  guard let worktree = resolveWorktree(for: candidate, worktrees: worktrees) else {
    terminalLogger.warning(
      "tmux restore missing worktree window=\(candidate.windowID.rawValue) worktreeID=\(candidate.worktreeID)"
    )
    return false
  }
  let state = state(for: worktree)
  guard await state.restoreDetachedTmuxCard(candidate) != nil else { return false }
  selectedWorktreeID = worktree.id
  return true
}

private func resolveWorktree(
  for candidate: TmuxDetachedCardCandidate,
  worktrees: [Worktree]
) -> Worktree? {
  if let exact = worktrees.first(where: { $0.id == candidate.worktreeID }) {
    return exact
  }
  if let pathMatch = worktrees.first(where: { $0.workingDirectory.path(percentEncoded: false) == candidate.worktreePath }) {
    return pathMatch
  }
  return Worktree(
    id: candidate.worktreeID,
    name: URL(fileURLWithPath: candidate.worktreePath, isDirectory: true).lastPathComponent,
    detail: candidate.worktreePath,
    workingDirectory: URL(fileURLWithPath: candidate.worktreePath, isDirectory: true),
    repositoryRootURL: URL(fileURLWithPath: candidate.repositoryRoot, isDirectory: true)
  )
}
```

- [ ] **Step 8: Run restore tests**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxTerminalControllerTests/prepareExistingWindowSelectsWindowInFreshAttachSession \
  -only-testing:supacodeTests/WorktreeTerminalManagerTests/restoresDetachedCardByAttachingExistingWindow \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add supacode/Features/Terminal/BusinessLogic/TmuxTerminalController.swift supacode/Features/Terminal/Models/WorktreeTerminalState.swift supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift supacode/Features/Terminal/Models/TerminalTabManager.swift supacodeTests/TmuxTerminalControllerTests.swift supacodeTests/WorktreeTerminalManagerTests.swift
git commit -m "feat(terminal): restore detached tmux cards"
```

### Task 6: Derive Recovery List Presentation from Raw Values

**Files:**
- Modify: `supacode/Features/Terminal/Models/TmuxCardRecovery.swift`
- Modify: `supacode/Features/Repositories/Reducer/RepositoriesFeature.swift:1960-1962`
- Modify: `supacodeTests/TmuxCardRecoveryTests.swift`
- Modify: `supacodeTests/CommandPaletteFeatureTests.swift`

- [ ] **Step 1: Write presentation tests**

Add to `TmuxCardRecoveryTests`:

```swift
@Test internal func presentationUsesRepositoryTitleDisplayPathAndRuntimeTitle() throws {
  let candidate = try #require(TmuxDetachedCardCandidate(record: TmuxRawWindowRecord(
    sessionName: "prowl-cards",
    windowID: "@21",
    windowName: "shell",
    activePath: "/Users/yam/Developer/Prowl/.worktrees/feature",
    activeCommand: "zsh",
    activeTitle: "codex",
    managed: "1",
    cardID: "card-21",
    worktreeID: "/Users/yam/Developer/Prowl/.worktrees/feature",
    worktreePath: "/Users/yam/Developer/Prowl/.worktrees/feature",
    repositoryRoot: "/Users/yam/Developer/Prowl",
    createdAt: "2026-05-28T12:00:00Z"
  )))

  let presentation = TmuxDetachedCardPresentation(
    candidate: candidate,
    repositoryName: "Prowl",
    homePath: "/Users/yam"
  )

  #expect(presentation.title == "Prowl / feature")
  #expect(presentation.subtitleLines == [
    "cwd: ~/Developer/Prowl/.worktrees/feature",
    "title: codex",
    "window: @21  card: card-21",
    "created: 2026-05-28T12:00:00Z",
  ])
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxCardRecoveryTests/presentationUsesRepositoryTitleDisplayPathAndRuntimeTitle \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because `TmuxDetachedCardPresentation` does not exist.

- [ ] **Step 3: Implement presentation value**

Add to `TmuxCardRecovery.swift`:

```swift
internal nonisolated struct TmuxDetachedCardPresentation: Equatable, Sendable {
  internal let id: TmuxDetachedCardCandidate.ID
  internal let title: String
  internal let subtitleLines: [String]

  internal init(
    candidate: TmuxDetachedCardCandidate,
    repositoryName: String,
    homePath: String = NSHomeDirectory()
  ) {
    id = candidate.id
    let worktreeLabel = URL(fileURLWithPath: candidate.worktreePath, isDirectory: true).lastPathComponent
    title = "\(repositoryName) / \(worktreeLabel.isEmpty ? candidate.worktreePath : worktreeLabel)"
    var lines: [String] = []
    if let displayPath = CanvasCurrentDirectoryFormatter.displayPath(for: candidate.activePath, homePath: homePath) {
      lines.append("cwd: \(displayPath)")
    }
    if let runtimeTitle = candidate.runtimeTitle {
      lines.append("title: \(runtimeTitle)")
    }
    lines.append("window: \(candidate.windowID.rawValue)  card: \(candidate.cardID.rawValue)")
    if let createdAt = candidate.createdAt {
      lines.append("created: \(createdAt)")
    }
    subtitleLines = lines
  }
}
```

- [ ] **Step 4: Add repository display-name resolver**

Add to `RepositoriesFeature.State` near `repositoryName(for:)`:

```swift
func repositoryDisplayName(forRoot rootURL: URL) -> String {
  let id = rootURL.standardizedFileURL.path(percentEncoded: false)
  if let customTitle = repositoryCustomTitles[id], !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    return customTitle
  }
  if let repository = repositories[id: id] {
    return repository.name
  }
  return Repository.name(for: rootURL)
}
```

- [ ] **Step 5: Run presentation tests**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxCardRecoveryTests/presentationUsesRepositoryTitleDisplayPathAndRuntimeTitle \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add supacode/Features/Terminal/Models/TmuxCardRecovery.swift supacode/Features/Repositories/Reducer/RepositoriesFeature.swift supacodeTests/TmuxCardRecoveryTests.swift
git commit -m "feat(command-palette): derive tmux card recovery labels"
```

### Task 7: Add Command Palette Restore Modes and Items

**Files:**
- Modify: `supacode/Features/CommandPalette/CommandPaletteItem.swift:24-170`
- Modify: `supacode/Features/CommandPalette/Reducer/CommandPaletteFeature.swift:7-305`
- Modify: `supacodeTests/CommandPaletteFeatureTests.swift`

- [ ] **Step 1: Write command-palette item tests**

Add to `CommandPaletteFeatureTests`:

```swift
@Test func commandPaletteItems_includeRestoreRunningTabAction() {
  let items = CommandPaletteFeature.commandPaletteItems(from: RepositoriesFeature.State())

  let item = items.first { $0.id == CommandPaletteItemID.globalRestoreRunningTab }

  #expect(item?.title == "Restore Running Tab")
  #expect(item?.kind == .restoreRunningTab)
}

@Test func detachedCardModeShowsOnlyRecoveryRows() {
  let candidate = TmuxDetachedCardCandidate(record: TmuxRawWindowRecord(
    sessionName: "prowl-cards",
    windowID: "@21",
    windowName: "shell",
    activePath: "/tmp/repo/wt",
    activeCommand: "zsh",
    activeTitle: "codex",
    managed: "1",
    cardID: "card-21",
    worktreeID: "/tmp/repo/wt",
    worktreePath: "/tmp/repo/wt",
    repositoryRoot: "/tmp/repo",
    createdAt: "2026-05-28T12:00:00Z"
  ))!
  let presentation = TmuxDetachedCardPresentation(candidate: candidate, repositoryName: "Repo", homePath: "/Users/yam")
  var state = CommandPaletteFeature.State()

  state.enterDetachedCardsMode(
    presentations: [presentation],
    diagnostics: [
      TmuxCardStructureDiagnostic(
        message: "Unexpected tmux sessions found. Restore will show safe managed cards only.",
        socketPath: "/tmp/prowl.sock",
        sessionNames: ["prowl-cards", "prowl-wt-old"],
        windowCountsBySession: ["prowl-cards": 1, "prowl-wt-old": 1]
      )
    ]
  )

  #expect(state.mode == .detachedCards)
  #expect(state.detachedCards.rows.first?.title == "Repo / wt")
  #expect(state.detachedCards.diagnostics.first?.sessionNames == ["prowl-cards", "prowl-wt-old"])
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/CommandPaletteFeatureTests/commandPaletteItems_includeRestoreRunningTabAction \
  -only-testing:supacodeTests/CommandPaletteFeatureTests/detachedCardModeShowsOnlyRecoveryRows \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because restore modes and item kinds do not exist.

- [ ] **Step 3: Add item IDs and kinds**

In `CommandPaletteItem.Kind`, add:

```swift
case restoreRunningTab
case restoreDetachedCard(TmuxDetachedCardCandidate.ID)
```

Update `isGlobal`, `isRootAction`, and `appShortcutCommandID`:

```swift
case .restoreRunningTab:
  return true
case .restoreDetachedCard:
  return false
```

```swift
case .restoreRunningTab:
  return true
case .restoreDetachedCard:
  return false
```

```swift
case .restoreRunningTab, .restoreDetachedCard:
  return nil
```

Add IDs to the local ID namespace used by this file:

```swift
enum CommandPaletteItemID {
  static let globalRestoreRunningTab = "global.restore-running-tab"

  static func restoreDetachedCard(_ id: TmuxDetachedCardCandidate.ID) -> String {
    "tmux.restore-card.\(id.rawValue)"
  }
}
```

If `CommandPaletteItemID` already lives later in `CommandPaletteFeature.swift`, add the two members there instead of creating a second enum.

- [ ] **Step 4: Add command-palette detached-card state**

In `CommandPaletteFeature.State`, add:

```swift
enum Mode: Equatable {
  case commands
  case detachedCards
}

struct DetachedCardsState: Equatable {
  var rows: [TmuxDetachedCardPresentation] = []
  var diagnostics: [TmuxCardStructureDiagnostic] = []
}

var mode: Mode = .commands
var detachedCards = DetachedCardsState()

mutating func enterDetachedCardsMode(
  presentations: [TmuxDetachedCardPresentation],
  diagnostics: [TmuxCardStructureDiagnostic]
) {
  mode = .detachedCards
  detachedCards = DetachedCardsState(rows: presentations, diagnostics: diagnostics)
  query = ""
  selectedIndex = presentations.isEmpty ? nil : 0
  isPresented = true
}

mutating func exitDetachedCardsMode() {
  mode = .commands
  detachedCards = DetachedCardsState()
  query = ""
  selectedIndex = nil
}
```

- [ ] **Step 5: Add reducer actions and delegates**

Add actions:

```swift
case enterDetachedCardsMode([TmuxDetachedCardPresentation], diagnostics: [TmuxCardStructureDiagnostic])
case exitDetachedCardsMode
```

Add delegates:

```swift
case restoreRunningTab
case restoreDetachedCard(TmuxDetachedCardCandidate.ID)
```

Handle state transitions:

```swift
case .enterDetachedCardsMode(let presentations, let diagnostics):
  state.enterDetachedCardsMode(presentations: presentations, diagnostics: diagnostics)
  return .none

case .exitDetachedCardsMode:
  state.exitDetachedCardsMode()
  return .none
```

Reset mode on dismiss:

```swift
case .setPresented(false):
  state.isPresented = false
  state.exitDetachedCardsMode()
  return .none
```

Map item kinds:

```swift
case .restoreRunningTab:
  return .restoreRunningTab
case .restoreDetachedCard(let id):
  return .restoreDetachedCard(id)
```

- [ ] **Step 6: Add the root command**

Append the root command in `commandPaletteItems(...)` after `Jump to Latest Unread`:

```swift
items.append(
  CommandPaletteItem(
    id: CommandPaletteItemID.globalRestoreRunningTab,
    title: "Restore Running Tab",
    subtitle: nil,
    kind: .restoreRunningTab
  )
)
```

Add the ID to `recencyRetentionIDs` global IDs.

- [ ] **Step 7: Run command-palette tests**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/CommandPaletteFeatureTests/commandPaletteItems_includeRestoreRunningTabAction \
  -only-testing:supacodeTests/CommandPaletteFeatureTests/detachedCardModeShowsOnlyRecoveryRows \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add supacode/Features/CommandPalette/CommandPaletteItem.swift supacode/Features/CommandPalette/Reducer/CommandPaletteFeature.swift supacodeTests/CommandPaletteFeatureTests.swift
git commit -m "feat(command-palette): add tmux card recovery mode"
```

### Task 8: Render Detached Cards in the Command Palette

**Files:**
- Modify: `supacode/Features/CommandPalette/Views/CommandPaletteOverlayView.swift:6-620`
- Modify: `supacodeTests/CommandPaletteFeatureTests.swift`

- [ ] **Step 1: Add view-state rows for detached-card mode**

In `CommandPaletteOverlayView.refreshFilteredItems(items:)`, branch on mode:

```swift
private func refreshFilteredItems(items: [CommandPaletteItem]) -> [CommandPaletteItem] {
  let now = Date.now
  let sourceItems: [CommandPaletteItem]
  switch store.mode {
  case .commands:
    sourceItems = items
  case .detachedCards:
    sourceItems = store.detachedCards.rows.map { row in
      CommandPaletteItem(
        id: CommandPaletteItemID.restoreDetachedCard(row.id),
        title: row.title,
        subtitle: row.subtitleLines.joined(separator: "\n"),
        kind: .restoreDetachedCard(row.id),
        priorityTier: 0
      )
    }
  }
  let updatedItems = CommandPaletteFeature.filterItems(
    items: sourceItems,
    query: store.query,
    recencyByID: store.recencyByItemID,
    now: now
  )
  filteredItems = updatedItems
  return updatedItems
}
```

- [ ] **Step 2: Render header, diagnostics, and empty state**

Inside `CommandPaletteCard`, add parameters:

```swift
let mode: CommandPaletteFeature.State.Mode
let detachedCards: CommandPaletteFeature.State.DetachedCardsState
```

Pass them from `CommandPaletteOverlayView`.

Add this above `CommandPaletteList`:

```swift
if mode == .detachedCards {
  CommandPaletteDetachedCardsHeader(diagnostics: detachedCards.diagnostics)
}
```

Add the header view:

```swift
private struct CommandPaletteDetachedCardsHeader: View {
  let diagnostics: [TmuxCardStructureDiagnostic]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Detached Cards")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
        Text(diagnostic.message)
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}
```

Change the empty list body:

```swift
if rows.isEmpty {
  CommandPaletteEmptyRowsView(message: emptyMessage)
} else {
  ScrollViewReader { proxy in
    ...
  }
}
```

Add `emptyMessage` to `CommandPaletteList`:

```swift
let emptyMessage: String
```

Pass:

```swift
emptyMessage: mode == .detachedCards ? "No detached running tabs" : ""
```

Add the empty view:

```swift
private struct CommandPaletteEmptyRowsView: View {
  let message: String

  var body: some View {
    Text(message)
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: CommandPaletteList.listHeight)
  }
}
```

- [ ] **Step 3: Update row icon/help for recovery rows**

In `CommandPaletteRowView.leadingIcon`, add:

```swift
case .restoreRunningTab, .restoreDetachedCard:
  return "arrow.counterclockwise"
```

In `helpText`, add:

```swift
case .restoreRunningTab:
  base = "Restore Running Tab"
case .restoreDetachedCard:
  base = "Restore Card"
```

In `badge`, `appIcon`, and `emphasis`, add `.restoreRunningTab` and `.restoreDetachedCard` beside other command-style rows.

- [ ] **Step 4: Run a compile test for the view**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/CommandPaletteFeatureTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS. This command compiles the app target and catches missing switch cases in the SwiftUI view.

- [ ] **Step 5: Commit**

```bash
git add supacode/Features/CommandPalette/Views/CommandPaletteOverlayView.swift supacodeTests/CommandPaletteFeatureTests.swift
git commit -m "feat(command-palette): render detached tmux cards"
```

### Task 9: Wire AppFeature and TerminalClient Restore Flow

**Files:**
- Modify: `supacode/Clients/Terminal/TerminalClient.swift:4-100`
- Modify: `supacode/App/supacodeApp.swift:237-263`
- Modify: `supacode/Features/App/Reducer/AppFeature.swift:77-1320`
- Modify: `supacodeTests/AppFeatureCommandPaletteTests.swift`

- [ ] **Step 1: Write AppFeature command-palette tests**

Add to `AppFeatureCommandPaletteTests`:

```swift
@Test(.dependencies) func restoreRunningTabLoadsDetachedCardsIntoPalette() async {
  let candidate = TmuxDetachedCardCandidate(record: TmuxRawWindowRecord(
    sessionName: "prowl-cards",
    windowID: "@21",
    windowName: "shell",
    activePath: "/tmp/repo/wt",
    activeCommand: "zsh",
    activeTitle: "codex",
    managed: "1",
    cardID: "card-21",
    worktreeID: "/tmp/repo/wt",
    worktreePath: "/tmp/repo/wt",
    repositoryRoot: "/tmp/repo",
    createdAt: "2026-05-28T12:00:00Z"
  ))!
  let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt", repoRoot: "/tmp/repo")
  let repository = makeRepository(rootPath: "/tmp/repo", name: "Repo", worktrees: [worktree])
  var repositoriesState = RepositoriesFeature.State()
  repositoriesState.repositories = [repository]
  let store = TestStore(initialState: AppFeature.State(repositories: repositoriesState)) {
    AppFeature()
  } withDependencies: {
    $0.terminalClient.detachedTmuxCards = {
      TmuxCardRecoverySnapshot(candidates: [candidate], diagnostics: [])
    }
  }

  await store.send(.commandPalette(.delegate(.restoreRunningTab)))
  await store.receive(\.commandPalette.enterDetachedCardsMode) {
    $0.commandPalette.mode = .detachedCards
    $0.commandPalette.isPresented = true
    $0.commandPalette.detachedCards.rows = [
      TmuxDetachedCardPresentation(candidate: candidate, repositoryName: "Repo")
    ]
    $0.commandPalette.selectedIndex = 0
  }
}

@Test(.dependencies) func restoreDetachedCardDelegatesToTerminalClient() async {
  let restoredIDs = LockIsolated<[TmuxDetachedCardCandidate.ID]>([])
  let id = TmuxDetachedCardCandidate.ID(rawValue: "prowl.sock:@21")
  let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt", repoRoot: "/tmp/repo")
  let repository = makeRepository(rootPath: "/tmp/repo", name: "Repo", worktrees: [worktree])
  var repositoriesState = RepositoriesFeature.State()
  repositoriesState.repositories = [repository]
  let store = TestStore(initialState: AppFeature.State(repositories: repositoriesState)) {
    AppFeature()
  } withDependencies: {
    $0.terminalClient.restoreDetachedTmuxCard = { candidateID, _ in
      restoredIDs.withValue { $0.append(candidateID) }
      return true
    }
  }

  await store.send(.commandPalette(.delegate(.restoreDetachedCard(id))))
  await store.finish()

  #expect(restoredIDs.value == [id])
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/AppFeatureCommandPaletteTests/restoreRunningTabLoadsDetachedCardsIntoPalette \
  -only-testing:supacodeTests/AppFeatureCommandPaletteTests/restoreDetachedCardDelegatesToTerminalClient \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because the new `TerminalClient` closures and AppFeature delegate cases do not exist.

- [ ] **Step 3: Extend TerminalClient**

Add closures:

```swift
var detachedTmuxCards: @MainActor @Sendable () async -> TmuxCardRecoverySnapshot
var restoreDetachedTmuxCard: @MainActor @Sendable (TmuxDetachedCardCandidate.ID, [Worktree]) async -> Bool
```

Update `liveValue` and `testValue`:

```swift
detachedTmuxCards: { TmuxCardRecoverySnapshot(candidates: [], diagnostics: []) },
restoreDetachedTmuxCard: { _, _ in false },
```

- [ ] **Step 4: Wire live client**

In `supacode/App/supacodeApp.swift`, add to `makeTerminalClient`:

```swift
detachedTmuxCards: {
  await terminalManager.detachedTmuxCardSnapshot()
},
restoreDetachedTmuxCard: { candidateID, worktrees in
  await terminalManager.restoreDetachedTmuxCard(candidateID, worktrees: worktrees)
},
```

- [ ] **Step 5: Handle AppFeature delegates**

Add worktree collection helper near `makeTerminalRestorableWorktrees`:

```swift
private func terminalRecoveryWorktrees(from repositories: [Repository]) -> [Worktree] {
  makeTerminalRestorableWorktrees(from: repositories)
}
```

Handle `restoreRunningTab`:

```swift
case .commandPalette(.delegate(.restoreRunningTab)):
  let repositoriesState = state.repositories
  return .run { send in
    let snapshot = await terminalClient.detachedTmuxCards()
    let presentations = snapshot.candidates.map { candidate in
      let rootURL = URL(fileURLWithPath: candidate.repositoryRoot, isDirectory: true)
      return TmuxDetachedCardPresentation(
        candidate: candidate,
        repositoryName: repositoriesState.repositoryDisplayName(forRoot: rootURL)
      )
    }
    await send(.commandPalette(.enterDetachedCardsMode(presentations, diagnostics: snapshot.diagnostics)))
  }
```

Handle `restoreDetachedCard`:

```swift
case .commandPalette(.delegate(.restoreDetachedCard(let candidateID))):
  let worktrees = terminalRecoveryWorktrees(from: Array(state.repositories.repositories))
  return .run { _ in
    _ = await terminalClient.restoreDetachedTmuxCard(candidateID, worktrees)
  }
```

- [ ] **Step 6: Run AppFeature tests**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/AppFeatureCommandPaletteTests/restoreRunningTabLoadsDetachedCardsIntoPalette \
  -only-testing:supacodeTests/AppFeatureCommandPaletteTests/restoreDetachedCardDelegatesToTerminalClient \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add supacode/Clients/Terminal/TerminalClient.swift supacode/App/supacodeApp.swift supacode/Features/App/Reducer/AppFeature.swift supacodeTests/AppFeatureCommandPaletteTests.swift
git commit -m "feat(app): wire tmux card recovery actions"
```

### Task 10: Verify End-to-End Behavior

**Files:**
- No source changes expected.

- [ ] **Step 1: Run focused recovery tests**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxTerminalTargetTests \
  -only-testing:supacodeTests/TmuxCardRecoveryTests \
  -only-testing:supacodeTests/TmuxTerminalControllerTests \
  -only-testing:supacodeTests/WorktreeTerminalManagerTests/restoresDetachedCardByAttachingExistingWindow \
  -only-testing:supacodeTests/CommandPaletteFeatureTests \
  -only-testing:supacodeTests/AppFeatureCommandPaletteTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 2: Run lint/check**

Run:

```bash
make check
```

Expected: PASS.

- [ ] **Step 3: Build the app**

Run:

```bash
make build-app
```

Expected: PASS and `GhosttyKit up-to-date` unless the local Ghostty checkout has changed.

- [ ] **Step 4: Manual recovery smoke test**

Run the app with anonymous tmux backing enabled, then verify:

```text
1. Create a new terminal tab.
2. In the terminal, run: sleep 600
3. Close the Prowl tab or Canvas card.
4. Open the command palette.
5. Select Restore Running Tab.
6. Confirm the detached list contains the closed card with window/card/cwd metadata.
7. Select the card.
8. Confirm the restored tab is still running the same sleep process.
9. Use Kill Terminal.
10. Reopen Restore Running Tab and confirm that window no longer appears.
```

Expected: The restore path attaches to the existing tmux window, does not create a new shell, and does not replay `sleep 600`.

- [ ] **Step 5: Inspect real tmux metadata**

Run:

```bash
tmux -S ~/Library/Caches/com.onevcat.prowl/tmux/prowl.sock list-windows -t prowl-cards \
  -F '#{window_id} #{@prowl.managed} #{@prowl.card_id} #{@prowl.worktree_id} #{@prowl.worktree_path} #{@prowl.repository_root} #{@prowl.created_at}'
```

Expected: Each Prowl-created window prints `1`, a stable card ID, worktree ID/path, repository root, and creation timestamp.

- [ ] **Step 6: Commit verification-only fixes if needed**

If verification required code changes, commit only those changed files:

```bash
git add <exact changed files>
git commit -m "fix(terminal): stabilize tmux card recovery"
```

If verification passed without changes, do not create an empty commit.

## Self-Review

Spec coverage:

- Global `prowl-cards` source of truth: Task 1.
- Raw `@prowl.*` metadata: Task 3.
- Live tmux restore list and filtering visible windows: Task 4.
- tmux window identity for dedup: Tasks 2 and 4.
- Diagnostics for legacy/invalid tmux structures: Tasks 4 and 8.
- Restore existing tmux window without replaying commands: Task 5.
- Presentation derivation from raw runtime fields: Task 6.
- Command Palette entry and detached-card list UI: Tasks 7, 8, and 9.
- Close detaches while Kill Terminal destroys: existing behavior is preserved and re-verified in Tasks 3, 5, and 10.

Red-flag scan:

- The plan avoids disallowed vague language, unspecified validation, and references to undefined task-owned types before their defining task.

Type consistency:

- `TmuxCardID`, `TmuxRawWindowRecord`, `TmuxDetachedCardCandidate`, `TmuxCardRecoverySnapshot`, and `TmuxDetachedCardPresentation` are introduced before use in later tasks.
- `TerminalClient.detachedTmuxCards` and `TerminalClient.restoreDetachedTmuxCard` match the AppFeature tests and live wiring.
