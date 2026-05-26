# Anonymous tmux Terminals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve long-running terminal processes when a Prowl tab or Canvas card is closed by backing eligible terminals with anonymous tmux sessions.

**Architecture:** Prowl keeps its own tab/card UI and stores a hidden tmux target for each terminal tab. Each Prowl tab maps to a tmux window, but each tab also gets a per-tab tmux client session so multiple Canvas cards can stay visible without fighting over one shared tmux active window. Ghostty remains the renderer by running a tmux attach client inside each surface; Prowl uses tmux commands/control-mode-compatible identifiers for creation, recovery, and kill semantics.

**Tech Stack:** Swift 6.2, SwiftUI, TCA, GhosttyKit embedded surfaces, tmux 3.6+, Swift Testing, existing `SupaLogger` logging.

---

## Scope

Build the anonymous tmux persistence path only. Do not expose tmux windows or panes as first-class UI in Canvas. Do not implement iTerm2-style complete tmux window/pane mirroring in this pass.

The MVP must support:

- New Prowl tab/card creates or attaches to an anonymous tmux-backed target.
- Closing a Prowl tab/card detaches/hides the Prowl surface and leaves the tmux window alive.
- A separate kill path can truly destroy the tmux-backed terminal.
- Existing non-tmux terminal behavior remains available through a feature flag or setting defaulted off during development.
- Layout restore can recover tmux-backed tabs by stable tmux ids.

## Existing Code Anchors

Current creation path:

```swift
// supacode/Features/Terminal/Models/WorktreeTerminalState.swift:290
func createTab(...) -> TerminalTabID? {
  let context: ghostty_surface_context_e =
    tabManager.tabs.isEmpty
    ? GHOSTTY_SURFACE_CONTEXT_WINDOW
    : GHOSTTY_SURFACE_CONTEXT_TAB

  let tabId = createTab(
    TabCreation(
      initialInput: resolvedInput,
      context: context,
      workingDirectoryOverride: workingDirectoryOverride
    )
  )
  return tabId
}
```

Current close path destroys the surface and therefore its child process:

```swift
// supacode/Features/Terminal/Models/WorktreeTerminalState.swift:588
func closeTab(_ tabId: TerminalTabID) {
  removeTree(for: tabId)
  tabManager.closeTab(tabId)
}
```

```swift
// supacode/Features/Terminal/Models/WorktreeTerminalState.swift:1941
private func removeTree(for tabId: TerminalTabID) {
  guard let tree = trees.removeValue(forKey: tabId) else { return }
  for surface in tree.leaves() {
    surface.closeSurface()
    surfaces.removeValue(forKey: surface.id)
  }
}
```

```swift
// supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift:328
func closeSurface() {
  if let surface {
    ghostty_surface_free(surface)
    self.surface = nil
    bridge.surface = nil
  }
}
```

GhosttyKit already exposes a command field in the embedded surface config:

```c
// ThirdParty/ghostty/include/ghostty.h:447
const char* command;
const char* initial_input;
bool wait_after_command;
```

## File Structure

- Create `supacode/Features/Terminal/Models/TmuxTerminalTarget.swift`
  - Pure value types for socket path, group session, client session, window id, pane id, and lifecycle state.
- Create `supacode/Features/Terminal/BusinessLogic/TmuxTerminalController.swift`
  - MainActor controller that shells out to `tmux -S <socket>` for deterministic operations and uses control-mode-compatible ids.
- Create `supacode/Features/Terminal/BusinessLogic/TmuxControlModeParser.swift`
  - Small parser for `%begin`, `%end`, `%error`, `%exit`, `%window-add`, `%window-close`, and `%session-window-changed` lines. This keeps the control-mode boundary explicit without making rendering depend on a full Swift terminal emulator.
- Modify `supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift`
  - Add an optional `command` parameter and pass it to `ghostty_surface_config_s.command`.
- Modify `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`
  - Store tmux targets by `TerminalTabID`, create tmux-backed surfaces, and split close into detach vs kill semantics.
- Modify `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
  - Own one `TmuxTerminalController`, pass it into states, and expose commands for detach/kill/recover.
- Modify `supacode/Clients/Terminal/TerminalClient.swift`
  - Add explicit commands for `killFocusedTab` and future recovery if needed.
- Modify `supacode/Features/App/Reducer/AppFeature.swift`
  - Keep current close actions as detach/hide for tmux-backed tabs and add kill action plumbing later.
- Modify `supacode/Features/Terminal/Models/TerminalLayoutSnapshotPayload.swift`
  - Persist tmux target metadata for tmux-backed tabs.
- Add tests in:
  - `supacodeTests/TmuxTerminalTargetTests.swift`
  - `supacodeTests/TmuxControlModeParserTests.swift`
  - `supacodeTests/WorktreeTerminalManagerTests.swift`
  - `supacodeTests/TerminalLayoutSnapshotPayloadTests.swift`
  - `supacodeTests/GhosttySurfaceViewTests.swift`

## tmux Mapping

Use a shared group per worktree and a per-tab client session:

```text
Prowl worktree       -> tmux group session: prowl-wt-<hash>
Prowl tab/card      -> tmux window id: @12
Prowl visible pane  -> tmux pane id: %34
Prowl tab renderer  -> tmux client session: prowl-tab-<tab uuid>
Ghostty surface     -> tmux -S <socket> -CC attach-session -t prowl-tab-<tab uuid>
```

The per-tab client session is necessary because normal tmux attached clients can otherwise share active-window state. This lets Canvas show several Prowl cards concurrently while each card remains attached to its intended tmux window.

## Close Semantics

```text
Close Tab / Canvas card X:
  Remove Prowl tab/card and close the Ghostty surface.
  Keep tmux window and pane alive.

Kill Terminal:
  Close Ghostty surface.
  Run tmux kill-window -t <window id>.
  Remove persisted tmux target.

App Quit:
  Close Ghostty attach clients.
  Keep tmux server/session/windows alive.

Layout Restore:
  Recreate Prowl tabs from persisted tmux targets.
  Attach new Ghostty surfaces to the matching client sessions/windows.
```

### Task 1: Add tmux Target Value Types

**Files:**
- Create: `supacode/Features/Terminal/Models/TmuxTerminalTarget.swift`
- Test: `supacodeTests/TmuxTerminalTargetTests.swift`

- [ ] **Step 1: Write target tests**

Add:

```swift
import Foundation
import Testing

@testable import supacode

struct TmuxTerminalTargetTests {
  @Test func sessionNamesAreStableAndShellSafe() {
    let target = TmuxTerminalTarget.make(
      appNamespace: "prowl",
      worktreeID: "/Users/yam/Developer/Prowl",
      tabID: TerminalTabID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
      socketRoot: URL(fileURLWithPath: "/tmp/prowl-tmux", isDirectory: true)
    )

    #expect(target.groupSession.hasPrefix("prowl-wt-"))
    #expect(target.clientSession == "prowl-tab-111111111111")
    #expect(target.socketURL.path == "/tmp/prowl-tmux/prowl.sock")
  }

  @Test func tmuxIdsRejectInvalidPrefixes() {
    #expect(TmuxWindowID(rawValue: "@12") != nil)
    #expect(TmuxPaneID(rawValue: "%34") != nil)
    #expect(TmuxWindowID(rawValue: "%12") == nil)
    #expect(TmuxPaneID(rawValue: "@34") == nil)
  }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxTerminalTargetTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because `TmuxTerminalTarget`, `TmuxWindowID`, and `TmuxPaneID` do not exist.

- [ ] **Step 3: Implement target types**

Create:

```swift
import CryptoKit
import Foundation

struct TmuxWindowID: Codable, Equatable, Hashable, Sendable {
  let rawValue: String

  init?(rawValue: String) {
    guard rawValue.first == "@", rawValue.dropFirst().allSatisfy(\.isNumber) else { return nil }
    self.rawValue = rawValue
  }
}

struct TmuxPaneID: Codable, Equatable, Hashable, Sendable {
  let rawValue: String

  init?(rawValue: String) {
    guard rawValue.first == "%", rawValue.dropFirst().allSatisfy(\.isNumber) else { return nil }
    self.rawValue = rawValue
  }
}

struct TmuxTerminalTarget: Codable, Equatable, Hashable, Sendable {
  let socketURL: URL
  let groupSession: String
  let clientSession: String
  var windowID: TmuxWindowID?
  var paneID: TmuxPaneID?

  static func make(
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

  private static func stableHash(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }
}
```

- [ ] **Step 4: Run tests**

Run the same `xcodebuild test` command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add supacode/Features/Terminal/Models/TmuxTerminalTarget.swift supacodeTests/TmuxTerminalTargetTests.swift
git commit -m "feat(terminal): add anonymous tmux target model"
```

### Task 2: Add tmux Control and Command Boundary

**Files:**
- Create: `supacode/Features/Terminal/BusinessLogic/TmuxControlModeParser.swift`
- Create: `supacode/Features/Terminal/BusinessLogic/TmuxTerminalController.swift`
- Test: `supacodeTests/TmuxControlModeParserTests.swift`

- [ ] **Step 1: Write parser tests**

Add:

```swift
import Testing

@testable import supacode

struct TmuxControlModeParserTests {
  @Test func parsesWindowNotifications() {
    let parser = TmuxControlModeParser()
    let events = parser.parseLines([
      "%session-changed $0 probe",
      "%window-add @1",
      "%session-window-changed $0 @1",
      "%window-close @0",
      "%exit",
    ])

    #expect(events == [
      .sessionChanged("$0", "probe"),
      .windowAdded(TmuxWindowID(rawValue: "@1")!),
      .sessionWindowChanged(sessionID: "$0", windowID: TmuxWindowID(rawValue: "@1")!),
      .windowClosed(TmuxWindowID(rawValue: "@0")!),
      .exit,
    ])
  }

  @Test func parsesCommandBlockOutput() {
    let parser = TmuxControlModeParser()
    let events = parser.parseLines([
      "%begin 1779800572 281 1",
      "@0 0 zsh 1",
      "@1 1 prowl-card 0",
      "%end 1779800572 281 1",
    ])

    #expect(events == [
      .commandOutput(commandNumber: 281, lines: [
        "@0 0 zsh 1",
        "@1 1 prowl-card 0",
      ]),
    ])
  }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxControlModeParserTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because `TmuxControlModeParser` does not exist.

- [ ] **Step 3: Implement parser**

Create:

```swift
import Foundation

enum TmuxControlModeEvent: Equatable, Sendable {
  case sessionChanged(String, String)
  case windowAdded(TmuxWindowID)
  case windowClosed(TmuxWindowID)
  case sessionWindowChanged(sessionID: String, windowID: TmuxWindowID)
  case commandOutput(commandNumber: Int, lines: [String])
  case commandError(commandNumber: Int, lines: [String])
  case exit
}

final class TmuxControlModeParser {
  private enum BlockKind {
    case output
    case error
  }

  private var blockKind: BlockKind?
  private var blockCommandNumber: Int?
  private var blockLines: [String] = []

  func parseLines(_ lines: [String]) -> [TmuxControlModeEvent] {
    var events: [TmuxControlModeEvent] = []
    for line in lines {
      if let event = parseLine(line) {
        events.append(event)
      }
    }
    return events
  }

  private func parseLine(_ line: String) -> TmuxControlModeEvent? {
    let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    if parts.count >= 4, parts[0] == "%begin" {
      blockKind = .output
      blockCommandNumber = Int(parts[2])
      blockLines.removeAll()
      return nil
    }
    if parts.count >= 4, parts[0] == "%end" {
      defer { resetBlock() }
      return .commandOutput(commandNumber: blockCommandNumber ?? -1, lines: blockLines)
    }
    if parts.count >= 4, parts[0] == "%error" {
      defer { resetBlock() }
      return .commandError(commandNumber: blockCommandNumber ?? -1, lines: blockLines)
    }
    if blockKind != nil {
      blockLines.append(line)
      return nil
    }
    if parts.count >= 3, parts[0] == "%session-changed" {
      return .sessionChanged(parts[1], parts[2])
    }
    if parts.count >= 2, parts[0] == "%window-add", let id = TmuxWindowID(rawValue: parts[1]) {
      return .windowAdded(id)
    }
    if parts.count >= 2, parts[0] == "%window-close", let id = TmuxWindowID(rawValue: parts[1]) {
      return .windowClosed(id)
    }
    if parts.count >= 3, parts[0] == "%session-window-changed", let id = TmuxWindowID(rawValue: parts[2]) {
      return .sessionWindowChanged(sessionID: parts[1], windowID: id)
    }
    if parts.first == "%exit" {
      return .exit
    }
    return nil
  }

  private func resetBlock() {
    blockKind = nil
    blockCommandNumber = nil
    blockLines.removeAll()
  }
}
```

- [ ] **Step 4: Add controller shell boundary**

Create the controller with an injectable executor:

```swift
import Foundation

struct TmuxCommandResult: Equatable, Sendable {
  let stdout: String
  let stderr: String
  let exitCode: Int32
}

typealias TmuxCommandExecutor = @Sendable (_ executable: URL, _ arguments: [String]) async throws -> TmuxCommandResult

@MainActor
final class TmuxTerminalController {
  private let executableURL: URL
  private let execute: TmuxCommandExecutor
  private let logger = SupaLogger("TmuxTerminal")

  init(
    executableURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
    execute: @escaping TmuxCommandExecutor = TmuxTerminalController.liveExecute
  ) {
    self.executableURL = executableURL
    self.execute = execute
  }

  func ensureGroup(target: TmuxTerminalTarget, cwd: URL) async throws {
    _ = try await run(["-S", target.socketURL.path, "has-session", "-t", target.groupSession], allowFailure: true)
    let result = try await run(["-S", target.socketURL.path, "has-session", "-t", target.groupSession], allowFailure: true)
    guard result.exitCode != 0 else { return }
    _ = try await run([
      "-S", target.socketURL.path,
      "-f", "/dev/null",
      "new-session", "-d",
      "-s", target.groupSession,
      "-n", "__prowl_bootstrap",
      "-c", cwd.path,
    ])
    _ = try await run(["-S", target.socketURL.path, "set-option", "-t", target.groupSession, "status", "off"])
  }

  func createWindow(target: TmuxTerminalTarget, cwd: URL, title: String) async throws -> TmuxTerminalTarget {
    var updated = target
    let result = try await run([
      "-S", target.socketURL.path,
      "new-window", "-d", "-P",
      "-F", "#{window_id} #{pane_id}",
      "-t", "\(target.groupSession):",
      "-n", title,
      "-c", cwd.path,
    ])
    let ids = result.stdout.split(whereSeparator: \.isWhitespace).map(String.init)
    if ids.count >= 2 {
      updated.windowID = TmuxWindowID(rawValue: ids[0])
      updated.paneID = TmuxPaneID(rawValue: ids[1])
    }
    try await ensureClientSession(target: updated)
    return updated
  }

  func ensureClientSession(target: TmuxTerminalTarget) async throws {
    let exists = try await run(["-S", target.socketURL.path, "has-session", "-t", target.clientSession], allowFailure: true)
    if exists.exitCode != 0 {
      _ = try await run([
        "-S", target.socketURL.path,
        "new-session", "-d",
        "-t", target.groupSession,
        "-s", target.clientSession,
      ])
    }
    if let windowID = target.windowID {
      _ = try await run(["-S", target.socketURL.path, "select-window", "-t", "\(target.clientSession):\(windowID.rawValue)"])
    }
    _ = try await run(["-S", target.socketURL.path, "set-option", "-t", target.clientSession, "status", "off"])
  }

  func attachCommand(for target: TmuxTerminalTarget) -> String {
    "tmux -S \(shellQuote(target.socketURL.path)) -CC attach-session -t \(shellQuote(target.clientSession))"
  }

  func killWindow(target: TmuxTerminalTarget) async throws {
    guard let windowID = target.windowID else { return }
    _ = try await run(["-S", target.socketURL.path, "kill-window", "-t", windowID.rawValue], allowFailure: true)
    _ = try await run(["-S", target.socketURL.path, "kill-session", "-t", target.clientSession], allowFailure: true)
  }

  private func run(_ args: [String], allowFailure: Bool = false) async throws -> TmuxCommandResult {
    let result = try await execute(executableURL, args)
    if result.exitCode != 0, !allowFailure {
      logger.warning("tmux failed args=\(args.joined(separator: " ")) stderr=\(result.stderr)")
    }
    return result
  }

  private static func liveExecute(executable: URL, arguments: [String]) async throws -> TmuxCommandResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return TmuxCommandResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
  }
}

nonisolated func shellQuote(_ value: String) -> String {
  "'\(value.replacing("'", with: "'\\''"))'"
}
```

- [ ] **Step 5: Run tests**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxControlModeParserTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add supacode/Features/Terminal/BusinessLogic/TmuxControlModeParser.swift \
  supacode/Features/Terminal/BusinessLogic/TmuxTerminalController.swift \
  supacodeTests/TmuxControlModeParserTests.swift
git commit -m "feat(terminal): add tmux control boundary"
```

### Task 3: Let Ghostty Surfaces Run tmux Attach Commands

**Files:**
- Modify: `supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift`
- Test: `supacodeTests/GhosttySurfaceViewTests.swift`

- [ ] **Step 1: Write command storage test**

Add:

```swift
@Test @MainActor func surfaceStoresConfiguredLaunchCommandForTesting() {
  let surfaceView = GhosttySurfaceView(
    runtime: GhosttyRuntime(),
    workingDirectory: URL(fileURLWithPath: "/tmp"),
    command: "tmux -CC attach-session -t prowl-tab-abc",
    context: GHOSTTY_SURFACE_CONTEXT_TAB,
    skipsSurfaceCreationForTesting: true
  )

  #expect(surfaceView.launchCommandForTesting == "tmux -CC attach-session -t prowl-tab-abc")
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/GhosttySurfaceViewTests/surfaceStoresConfiguredLaunchCommandForTesting \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because the initializer has no `command` argument.

- [ ] **Step 3: Add command parameter**

Modify the initializer and stored CString in `GhosttySurfaceView`:

```swift
private let launchCommand: String?
private let commandCString: UnsafeMutablePointer<CChar>?

init(
  runtime: GhosttyRuntime,
  workingDirectory: URL?,
  command: String? = nil,
  initialInput: String? = nil,
  fontSize: Float32? = nil,
  context: ghostty_surface_context_e,
  environment: [String: String] = [:],
  skipsSurfaceCreationForTesting: Bool = false
) {
  self.launchCommand = command
  if let command {
    commandCString = command.withCString { strdup($0) }
  } else {
    commandCString = nil
  }
  ...
}
```

Pass the value into Ghostty:

```swift
// supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift:1078
private func createSurface() {
  var config = ghostty_surface_config_new()
  config.command = commandCString.map { UnsafePointer($0) }
  config.initial_input = initialInputCString.map { UnsafePointer($0) }
  surface = ghostty_surface_new(app, &config)
}
```

Free it in `deinit`:

```swift
if let commandCString {
  free(commandCString)
}
```

Expose test-only readback:

```swift
var launchCommandForTesting: String? {
  launchCommand
}
```

- [ ] **Step 4: Run test**

Run the same `xcodebuild test` command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift supacodeTests/GhosttySurfaceViewTests.swift
git commit -m "feat(terminal): allow ghostty surfaces to run launch commands"
```

### Task 4: Create tmux-backed Tabs Behind a Feature Flag

**Files:**
- Modify: `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`
- Modify: `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
- Test: `supacodeTests/WorktreeTerminalManagerTests.swift`

- [ ] **Step 1: Add manager/state test**

Add:

```swift
@Test func tmuxBackedTabUsesAttachCommand() async {
  let controller = TmuxTerminalController(execute: { _, args in
    if args.contains("new-window") {
      return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
    }
    return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
  })
  let manager = WorktreeTerminalManager(
    runtime: GhosttyRuntime(),
    tmuxController: controller,
    usesAnonymousTmux: true
  )
  let worktree = makeWorktree(id: "/tmp/repo/wt-a", name: "wt-a")

  await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false)
  let state = manager.state(for: worktree)
  let tabID = state.tabManager.selectedTabId!
  let surface = state.surfaceView(for: tabID)!

  #expect(surface.launchCommandForTesting?.contains("tmux -S") == true)
  #expect(surface.launchCommandForTesting?.contains("-CC attach-session") == true)
  #expect(state.tmuxTargetForTesting(tabID)?.windowID == TmuxWindowID(rawValue: "@7"))
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/WorktreeTerminalManagerTests/tmuxBackedTabUsesAttachCommand \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because manager/state have no tmux injection.

- [ ] **Step 3: Thread tmux dependencies**

Add properties:

```swift
// WorktreeTerminalManager
private let tmuxController: TmuxTerminalController?
private let usesAnonymousTmux: Bool
```

Initializer addition:

```swift
init(
  runtime: GhosttyRuntime,
  preferredFontSize: Float32? = nil,
  layoutPersistence: TerminalLayoutPersistenceClient = .liveValue,
  inputSourceCoordinator: TerminalInputSourceCoordinator = TerminalInputSourceCoordinator(),
  tmuxController: TmuxTerminalController? = nil,
  usesAnonymousTmux: Bool = false
) {
  self.tmuxController = tmuxController
  self.usesAnonymousTmux = usesAnonymousTmux
  ...
}
```

Pass into `WorktreeTerminalState`:

```swift
let state = WorktreeTerminalState(
  runtime: runtime!,
  worktree: worktree,
  runSetupScript: runSetupScript,
  defaultFontSize: preferredFontSize,
  tmuxController: usesAnonymousTmux ? tmuxController : nil
)
```

- [ ] **Step 4: Add tmux-backed creation path**

Add state storage:

```swift
private let tmuxController: TmuxTerminalController?
private var tmuxTargetsByTabID: [TerminalTabID: TmuxTerminalTarget] = [:]
```

Change `createTabAsync` in the manager to call an async state method when tmux is enabled:

```swift
let tabId = await state.createTabAsync(
  setupScript: setupScript,
  initialInput: initialInput,
  inheritFromFocusedSurface: inheritFromFocusedSurface,
  workingDirectoryOverride: workingDirectory
)
```

Implement:

```swift
@discardableResult
func createTabAsync(
  setupScript: String? = nil,
  initialInput: String? = nil,
  inheritFromFocusedSurface: Bool = true,
  workingDirectoryOverride: URL? = nil
) async -> TerminalTabID? {
  guard let tmuxController else {
    return createTab(
      setupScript: setupScript,
      initialInput: initialInput,
      inheritFromFocusedSurface: inheritFromFocusedSurface,
      workingDirectoryOverride: workingDirectoryOverride
    )
  }

  let tabId = tabManager.createTab(title: "\(worktree.name) \(nextTabIndex())", icon: "terminal")
  var target = TmuxTerminalTarget.make(
    appNamespace: "prowl",
    worktreeID: worktree.id,
    tabID: tabId,
    socketRoot: URL.applicationSupportDirectory.appending(path: "Prowl/tmux", directoryHint: .isDirectory)
  )
  let cwd = workingDirectoryOverride ?? worktree.workingDirectory
  try? FileManager.default.createDirectory(at: target.socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try? await tmuxController.ensureGroup(target: target, cwd: cwd)
  target = (try? await tmuxController.createWindow(target: target, cwd: cwd, title: worktree.name)) ?? target
  tmuxTargetsByTabID[tabId] = target

  let tree = splitTree(
    for: tabId,
    initialInput: nil,
    workingDirectoryOverride: cwd,
    context: tabManager.tabs.count == 1 ? GHOSTTY_SURFACE_CONTEXT_WINDOW : GHOSTTY_SURFACE_CONTEXT_TAB,
    launchCommandOverride: tmuxController.attachCommand(for: target)
  )
  tabIsRunningById[tabId] = false
  if let surface = tree.root?.leftmostLeaf() {
    focusSurface(surface, in: tabId)
    onFocusedCommandSurfaceCreated?(surface.id)
  }
  if let initialInput {
    sendInitialInputToTmux(initialInput, target: target)
  }
  onTabCreated?()
  return tabId
}
```

Add a `launchCommandOverride` parameter through `splitTree` and `createSurface`:

```swift
private func createSurface(..., launchCommandOverride: String? = nil) -> GhosttySurfaceView {
  GhosttySurfaceView(
    runtime: runtime,
    workingDirectory: workingDirectoryOverride ?? inherited.workingDirectory ?? worktree.workingDirectory,
    command: launchCommandOverride,
    initialInput: initialInput,
    fontSize: resolvedFontSize,
    context: context,
    environment: worktree.scriptEnvironment
  )
}
```

- [ ] **Step 5: Add test-only accessors**

Add:

```swift
func tmuxTargetForTesting(_ tabID: TerminalTabID) -> TmuxTerminalTarget? {
  tmuxTargetsByTabID[tabID]
}
```

Add manager helper:

```swift
func createTabForTesting(in worktree: Worktree, runSetupScriptIfNew: Bool) async {
  await createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew)
}
```

- [ ] **Step 6: Run focused tests**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/WorktreeTerminalManagerTests/tmuxBackedTabUsesAttachCommand \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add supacode/Features/Terminal/Models/WorktreeTerminalState.swift \
  supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift \
  supacodeTests/WorktreeTerminalManagerTests.swift
git commit -m "feat(terminal): create anonymous tmux-backed tabs"
```

### Task 5: Change Close to Detach and Add Kill Semantics

**Files:**
- Modify: `supacode/Clients/Terminal/TerminalClient.swift`
- Modify: `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`
- Modify: `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
- Modify: `supacode/Features/App/Reducer/AppFeature.swift`
- Test: `supacodeTests/WorktreeTerminalManagerTests.swift`

- [ ] **Step 1: Add close-vs-kill test**

Add:

```swift
@Test func closingTmuxBackedTabDoesNotKillWindow() async {
  var tmuxArgs: [[String]] = []
  let controller = TmuxTerminalController(execute: { _, args in
    tmuxArgs.append(args)
    if args.contains("new-window") {
      return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
    }
    return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
  })
  let manager = WorktreeTerminalManager(
    runtime: GhosttyRuntime(),
    tmuxController: controller,
    usesAnonymousTmux: true
  )
  let worktree = makeWorktree(id: "/tmp/repo/wt-a", name: "wt-a")

  await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false)
  _ = manager.closeFocusedTab(in: worktree)

  #expect(!tmuxArgs.contains { $0.contains("kill-window") })
}

@Test func killingTmuxBackedTabKillsWindow() async {
  var tmuxArgs: [[String]] = []
  let controller = TmuxTerminalController(execute: { _, args in
    tmuxArgs.append(args)
    if args.contains("new-window") {
      return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
    }
    return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
  })
  let manager = WorktreeTerminalManager(
    runtime: GhosttyRuntime(),
    tmuxController: controller,
    usesAnonymousTmux: true
  )
  let worktree = makeWorktree(id: "/tmp/repo/wt-a", name: "wt-a")

  await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false)
  await manager.killFocusedTabForTesting(in: worktree)

  #expect(tmuxArgs.contains { $0.contains("kill-window") && $0.contains("@7") })
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/WorktreeTerminalManagerTests/closingTmuxBackedTabDoesNotKillWindow \
  -only-testing:supacodeTests/WorktreeTerminalManagerTests/killingTmuxBackedTabKillsWindow \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because kill command plumbing does not exist.

- [ ] **Step 3: Add terminal command**

Add:

```swift
// TerminalClient.Command
case killFocusedTab(Worktree)
```

Handle it in `WorktreeTerminalManager.handleTabCommand`:

```swift
case .killFocusedTab(let worktree):
  Task { await killFocusedTab(in: worktree) }
```

Add manager method:

```swift
func killFocusedTab(in worktree: Worktree) async {
  let state = state(for: worktree)
  await state.killFocusedTab()
}
```

- [ ] **Step 4: Implement state kill**

Add:

```swift
func killFocusedTab() async {
  guard let tabId = tabManager.selectedTabId else { return }
  if let target = tmuxTargetsByTabID[tabId], let tmuxController {
    try? await tmuxController.killWindow(target: target)
    tmuxTargetsByTabID.removeValue(forKey: tabId)
  }
  closeTab(tabId)
}
```

Keep existing `closeTab(_:)` as detach for tmux-backed tabs by only closing the local Ghostty attach surface:

```swift
func closeTab(_ tabId: TerminalTabID) {
  removeTree(for: tabId)
  tabManager.closeTab(tabId)
  if tmuxTargetsByTabID[tabId] == nil {
    cleanupNonPersistentTabState(tabId)
  }
  ...
}
```

The important behavior is that `removeTree(for:)` still calls `surface.closeSurface()`, but it does not run `tmux kill-window`.

- [ ] **Step 5: Wire AppFeature action**

Add:

```swift
// AppFeature.Action
case killTab
```

Reducer:

```swift
case .killTab:
  guard let worktree = terminalCommandWorktree(state: state) else {
    return .none
  }
  analyticsClient.capture("terminal_tab_killed", nil)
  return .run { _ in
    await terminalClient.send(.killFocusedTab(worktree))
  }
```

Do not change current `.closeTab` analytics or menu label yet; close remains the default user path.

- [ ] **Step 6: Run tests**

Run the same focused `xcodebuild test` command.

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add supacode/Clients/Terminal/TerminalClient.swift \
  supacode/Features/Terminal/Models/WorktreeTerminalState.swift \
  supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift \
  supacode/Features/App/Reducer/AppFeature.swift \
  supacodeTests/WorktreeTerminalManagerTests.swift
git commit -m "feat(terminal): detach tmux tabs on close"
```

### Task 6: Persist tmux Targets in Layout Snapshots

**Files:**
- Modify: `supacode/Features/Terminal/Models/TerminalLayoutSnapshotPayload.swift`
- Modify: `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`
- Test: `supacodeTests/TerminalLayoutSnapshotPayloadTests.swift`

- [ ] **Step 1: Add snapshot round-trip test**

Add:

```swift
@Test func decodeValidatedRoundTripsTmuxTarget() throws {
  let target = TerminalLayoutSnapshotPayload.SnapshotTmuxTarget(
    socketPath: "/Users/yam/Library/Application Support/Prowl/tmux/prowl.sock",
    groupSession: "prowl-wt-abcdef12",
    clientSession: "prowl-tab-111111111111",
    windowID: "@7",
    paneID: "%9"
  )
  let payload = makePayload(tmuxTarget: target)
  let data = try JSONEncoder().encode(payload)

  let decoded = TerminalLayoutSnapshotPayload.decodeValidated(from: data)

  #expect(decoded?.worktrees.first?.tabs.first?.tmuxTarget == target)
}
```

Update the helper:

```swift
func makeTab(
  tabID: String = "tab-1",
  title: String? = "tab",
  customTitle: String? = nil,
  icon: String? = "terminal",
  splitRoot: TerminalLayoutSnapshotPayload.SnapshotSplitNode = .leaf(surfaceID: "surface-1"),
  tmuxTarget: TerminalLayoutSnapshotPayload.SnapshotTmuxTarget? = nil
) -> TerminalLayoutSnapshotPayload.SnapshotTab {
  TerminalLayoutSnapshotPayload.SnapshotTab(
    tabID: tabID,
    title: title,
    customTitle: customTitle,
    icon: icon,
    splitRoot: splitRoot,
    tmuxTarget: tmuxTarget
  )
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TerminalLayoutSnapshotPayloadTests/decodeValidatedRoundTripsTmuxTarget \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because `SnapshotTmuxTarget` does not exist.

- [ ] **Step 3: Add snapshot schema**

Add:

```swift
nonisolated struct SnapshotTmuxTarget: Codable, Equatable, Sendable {
  let socketPath: String
  let groupSession: String
  let clientSession: String
  let windowID: String
  let paneID: String

  var isValid: Bool {
    !socketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !groupSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !clientSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && TmuxWindowID(rawValue: windowID) != nil
      && TmuxPaneID(rawValue: paneID) != nil
  }
}
```

Extend `SnapshotTab`:

```swift
let tmuxTarget: SnapshotTmuxTarget?
```

Validate:

```swift
if let tmuxTarget, !tmuxTarget.isValid {
  return false
}
```

Keep migration compatible by defaulting `tmuxTarget` to nil in all initializers.

- [ ] **Step 4: Persist and restore target in state**

When snapshotting a tab:

```swift
let snapshotTmuxTarget = tmuxTargetsByTabID[tab.id].map {
  TerminalLayoutSnapshotPayload.SnapshotTmuxTarget(
    socketPath: $0.socketURL.path,
    groupSession: $0.groupSession,
    clientSession: $0.clientSession,
    windowID: $0.windowID?.rawValue ?? "",
    paneID: $0.paneID?.rawValue ?? ""
  )
}
```

Pass it into `SnapshotTab`.

When restoring:

```swift
if let snapshotTarget = entry.snapshotTab.tmuxTarget,
  let windowID = TmuxWindowID(rawValue: snapshotTarget.windowID),
  let paneID = TmuxPaneID(rawValue: snapshotTarget.paneID)
{
  tmuxTargetsByTabID[entry.tabID] = TmuxTerminalTarget(
    socketURL: URL(fileURLWithPath: snapshotTarget.socketPath),
    groupSession: snapshotTarget.groupSession,
    clientSession: snapshotTarget.clientSession,
    windowID: windowID,
    paneID: paneID
  )
}
```

For restored tmux tabs, create the surface with the tmux attach command instead of a plain shell.

- [ ] **Step 5: Run snapshot tests**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TerminalLayoutSnapshotPayloadTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add supacode/Features/Terminal/Models/TerminalLayoutSnapshotPayload.swift \
  supacode/Features/Terminal/Models/WorktreeTerminalState.swift \
  supacodeTests/TerminalLayoutSnapshotPayloadTests.swift
git commit -m "feat(terminal): persist anonymous tmux targets"
```

### Task 7: Add Setting and UI-safe Defaults

**Files:**
- Modify: `supacode/Features/Settings/Models/UserRepositorySettings.swift`
- Modify: `supacode/Features/Settings/Views/WorktreeSettingsView.swift`
- Modify: `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
- Test: `supacodeTests/SettingsFilePersistenceTests.swift`

- [ ] **Step 1: Add setting persistence test**

Add:

```swift
@Test func repositorySettingsRoundTripsAnonymousTmuxPreference() throws {
  var settings = UserRepositorySettings()
  settings.usesAnonymousTmuxTerminals = true

  let data = try JSONEncoder().encode(settings)
  let decoded = try JSONDecoder().decode(UserRepositorySettings.self, from: data)

  #expect(decoded.usesAnonymousTmuxTerminals == true)
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/SettingsFilePersistenceTests/repositorySettingsRoundTripsAnonymousTmuxPreference \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL because the setting does not exist.

- [ ] **Step 3: Add setting**

Add:

```swift
var usesAnonymousTmuxTerminals = false
```

Expose in worktree settings as a toggle:

```swift
Toggle("Use anonymous tmux for new terminals", isOn: $settings.usesAnonymousTmuxTerminals)
  .help("New terminals keep running after their Prowl tab or Canvas card is closed.")
```

Keep the default `false` until the feature is manually verified on a real app build.

- [ ] **Step 4: Thread setting into tab creation**

At tab creation, read the selected worktree setting and pass `usesAnonymousTmux` into the manager/state creation path. Preserve existing plain Ghostty behavior when the setting is off.

Use this decision shape:

```swift
@SharedReader(.userRepositorySettings(worktree.repositoryRootURL))
var userSettings = UserRepositorySettings()
let useTmux = userSettings.usesAnonymousTmuxTerminals
```

- [ ] **Step 5: Run tests**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/SettingsFilePersistenceTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add supacode/Features/Settings/Models/UserRepositorySettings.swift \
  supacode/Features/Settings/Views/WorktreeSettingsView.swift \
  supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift \
  supacodeTests/SettingsFilePersistenceTests.swift
git commit -m "feat(settings): add anonymous tmux terminal preference"
```

### Task 8: Manual Verification and Build

**Files:**
- No source changes unless verification exposes a bug.

- [ ] **Step 1: Run focused tests**

Run:

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TmuxTerminalTargetTests \
  -only-testing:supacodeTests/TmuxControlModeParserTests \
  -only-testing:supacodeTests/WorktreeTerminalManagerTests \
  -only-testing:supacodeTests/TerminalLayoutSnapshotPayloadTests \
  -only-testing:supacodeTests/GhosttySurfaceViewTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS.

- [ ] **Step 2: Run app build**

Run:

```bash
make build-app
```

Expected: build succeeds.

- [ ] **Step 3: Manual runtime verification**

Install or run the debug app using the normal project workflow, then:

1. Enable "Use anonymous tmux for new terminals" for one repository.
2. Create a new terminal.
3. Run:

```bash
sleep 600
```

4. Close the Prowl tab or Canvas card.
5. In a separate shell, verify tmux still has the pane:

```bash
tmux -S "$HOME/Library/Application Support/Prowl/tmux/prowl.sock" list-panes -a -F '#{session_name} #{window_id} #{pane_id} #{pane_current_command}'
```

Expected: a pane for the closed terminal still exists and shows `sleep` or the shell running it.

6. Reopen or restore the Prowl tab.
7. Verify the terminal is attached to the same running job.
8. Use the explicit kill action.
9. Verify the tmux window is gone:

```bash
tmux -S "$HOME/Library/Application Support/Prowl/tmux/prowl.sock" list-windows -a -F '#{window_id} #{window_name}'
```

Expected: the killed window id is absent.

- [ ] **Step 4: Commit verification fixes**

If a runtime bug is fixed during verification:

```bash
git add <only-the-files-changed-for-the-fix>
git commit -m "fix(terminal): stabilize anonymous tmux attachment"
```

If no source changes are needed, do not create an empty commit.

## Risks and Guardrails

- **Concurrent Canvas cards:** Do not attach several normal tmux clients to one shared session without per-tab client sessions. That can make active-window state bleed between cards.
- **tmux not installed:** Detect missing `tmux` before creating a tmux-backed tab. Fall back to a plain Ghostty terminal and show a toast that tmux was unavailable.
- **Ghostty `command` behavior:** Embedded Ghostty currently treats `command` as script-like and may keep a surface open after the command exits. This is acceptable for the first pass because Prowl controls tab removal; do not patch Ghostty unless manual verification shows stuck surfaces.
- **Setup script and custom command input:** Send commands to the tmux pane through tmux `send-keys` once the pane id exists. Do not rely on startup input racing with `tmux attach`.
- **Agent detection:** Existing detection sees `tmux` as a fallback process. Keep `TerminalInputContextClassifier` viewport fallback active and add tmux pane command inspection later only if agent state becomes unreliable.
- **Prune behavior:** Worktree prune should close Prowl surfaces but not kill tmux windows by default. Add a later cleanup UI for orphaned tmux sessions.

## Self-Review

- Spec coverage: The plan covers anonymous tmux creation, close-as-detach, explicit kill, restore metadata, control-mode boundaries, no tmux UI exposure, and Canvas concurrency.
- Placeholder scan: No task depends on undefined future work. Optional future iTerm2-style mirroring is deliberately outside scope.
- Type consistency: `TmuxTerminalTarget`, `TmuxWindowID`, `TmuxPaneID`, `TmuxTerminalController`, and `TmuxControlModeParser` are introduced before later tasks reference them.
