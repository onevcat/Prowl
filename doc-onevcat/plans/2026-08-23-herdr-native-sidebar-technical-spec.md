# Prowl Clean Mode Herdr Native Sidebar 技术 Spec

> 本文基于 [Herdr Native Sidebar 扩展评估](2026-08-23-herdr-native-sidebar-evaluation.md)，用于实现阶段。

**Goal:** 在 Prowl Clean Mode 中新增一个独立的 native Herdr Sidebar，读取 Herdr runtime 的 workspace、tab、pane、agent
状态并执行 focus action；不恢复、修改或复用 Prowl 原有 Sidebar。

**Architecture:** Clean runtime 继续拥有一个 Ghostty terminal surface。外层 foreground process 被确认是 `herdr`
且 JSON socket 通过 protocol check 后，Clean root 旁边显示 `HerdrSidebarView`。Sidebar 通过独立的 TCA feature 和
Herdr socket client 维护 `session.snapshot` 缓存及 lifecycle event refresh；Ghostty surface 继续显示用户手动启动的
Herdr client，因此首期不实现 terminal stream 或 Herdr binary client protocol。

**Tech Stack:** Swift 6.2、macOS 26、SwiftUI、The Composable Architecture、GhosttyKit、Unix domain socket、NDJSON、
`SupaLogger`、`TestClock`。

## Global Constraints

- 目标运行时是现有 Prowl Clean Mode；Standard、Shelf、Canvas、Freestyle 和 Prowl repository/worktree Sidebar 不在本功能内。
- 不恢复、改造、复用 `RepositoriesFeature` 或 Standard `SidebarView` 的 state、row model、reducer 和 action。
- Herdr 首期只使用 default local session 的 JSON Unix socket；不支持 named session、remote Herdr、Windows named pipe 或自定义 `HERDR_SOCKET_PATH`。
- 每个 JSON request 使用独立短连接；`events.subscribe` 使用独立长连接；不能复用同一 socket connection 发送多个普通 request。
- 所有新增 `@Observable` class 必须是 `@MainActor`；TCA reducer state 使用 `@ObservableState`。
- Reducer 逻辑必须有测试；异步计时使用注入的 `TestClock`，禁止生产测试使用 `Task.sleep`。
- 所有日志使用 `SupaLogger`；禁止新增 `print()` 或直接使用 `os.Logger`。
- Herdr socket 错误不能影响 Ghostty surface 的输入、渲染、关闭或现有输入法 adapter。
- 本 spec 首期不接管 Herdr terminal 内容，不实现 `terminal attach`、`terminal session control` 或 binary client protocol。

## 1. Scope

### 1.1 Included

- Clean foreground process 是 `herdr` 时连接 Herdr default socket。
- 请求一次 `session.snapshot`，建立 native Sidebar 本地缓存。
- 订阅 workspace、tab、pane 和 layout lifecycle events。
- 收到事件后 debounce 并重新请求完整 snapshot。
- 显示 workspace、tab、Agent pane 和普通 non-Agent pane。
- 通过 `workspace.focus`、`tab.focus`、`pane.focus` 执行 Sidebar focus action。
- Herdr 退出、socket 不可用或 protocol 不兼容时隐藏 Sidebar，并恢复 terminal full width。
- 支持 socket 重连、过期 response 丢弃和 selection reconciliation。

### 1.2 Excluded

- 复用 Prowl 原 Sidebar 的 UI、model 或 reducer。
- 把 Herdr workspace/tab/pane 写入 Prowl repository/worktree persistence。
- 自动启动或 attach Herdr。
- 从 Prowl 自己渲染 Herdr pane terminal 内容。
- 通过 `pane.send_input`、`pane.send_keys` 或其它控制 API 驱动 pane 内容。
- Herdr binary client socket、semantic `FrameData`、ANSI frame bridge。
- named session、remote Herdr 和 `HERDR_SOCKET_PATH` override。

## 2. Existing Integration Points

### 2.1 Clean root

当前 [CleanRootView.swift](/Users/yam/Developer/Prowl/supacode/Features/Clean/CleanRootView.swift:4) 只负责显示
`CleanTerminalHost.surface`：

```swift
if let surface = terminalHost.surface {
  GhosttyTerminalView(surfaceView: surface)
}
```

实现后改为：

```swift
HStack(spacing: 0) {
  if herdrSidebar.isVisible {
    HerdrSidebarView(store: store.scope(state: \.herdrSidebar, action: \.herdrSidebar))
      .frame(width: HerdrSidebarLayout.width)
  }

  if let surface = terminalHost.surface {
    GhosttyTerminalView(surfaceView: surface)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
```

`CleanRootView` 不引入 `NavigationSplitView`，也不挂载 Standard `SidebarView`。

### 2.2 Clean TCA feature

当前 [CleanAppFeature.swift](/Users/yam/Developer/Prowl/supacode/Features/Clean/CleanAppFeature.swift:4) 已经是
Clean runtime 的 TCA root。新增 `HerdrSidebarFeature` scope：

```swift
@Reducer
internal struct CleanAppFeature {
  @ObservableState
  internal struct State: Equatable {
    internal var settings: SettingsFeature.State
    internal var updates = UpdatesFeature.State()
    internal var herdrSidebar = HerdrSidebarFeature.State()
    @Presents internal var alert: AlertState<Alert>?
  }

  internal enum Action {
    case appLaunched
    case herdrForegroundChanged(Bool)
    case herdrSidebar(HerdrSidebarFeature.Action)
    case herdrCompatibilityFailure(HerdrSocketError)
    // Existing actions remain unchanged.
  }
}
```

`CleanAppFeature` 只负责组合 scope、转发 foreground lifecycle 和共享 compatibility alert。snapshot、event stream、
debounce、selection 和 focus request 由 `HerdrSidebarFeature` 负责。

### 2.3 CleanTerminalHost lifecycle callback

当前 [CleanTerminalHost.swift](/Users/yam/Developer/Prowl/supacode/Features/Clean/CleanTerminalHost.swift:77) 已经拥有
`isHerdrForeground` 和 `HerdrInputContextAdapter`。新增一个回调：

```swift
internal typealias HerdrForegroundHandler = @MainActor (Bool) -> Void
```

在 foreground 状态从 `false -> true` 或 `true -> false` 时只调用一次：

```swift
if nextIsHerdrForeground != isHerdrForeground {
  isHerdrForeground = nextIsHerdrForeground
  onHerdrForegroundChanged(nextIsHerdrForeground)
}
```

回调由 `makeCleanRuntime` 注入，发送 `cleanStore.send(.herdrForegroundChanged(value))`。输入法 adapter 保持现有职责，
不要让 `CleanRootView` 直接读取或修改 `CleanTerminalHost` 的私有 process state。

## 3. Herdr Wire Contract

### 3.1 Socket path

复用 [HerdrWireModels.swift](/Users/yam/Developer/Prowl/supacode/Infrastructure/Herdr/HerdrWireModels.swift:14) 的路径规则：

```text
$XDG_CONFIG_HOME/herdr/herdr.sock
或
$HOME/.config/herdr/herdr.sock
```

首期不读 Herdr 子进程环境中的 `HERDR_SOCKET_PATH`，不读取 named session。socket path 为空、超出 Unix path 长度或
文件不存在时，Sidebar 保持隐藏。

### 3.2 Protocol compatibility

复用当前 `HerdrProtocolCompatibility.supportedVersions = 19...20`。Sidebar 和 input context adapter 必须共享同一
protocol range，但每个 adapter 自己管理 lifecycle。`ping` 响应不是 Sidebar snapshot；必须通过 `ping` 成功后再请求
`session.snapshot`。

### 3.3 Snapshot models

扩展 `HerdrWireModels.swift`，只声明 Sidebar 实际使用的字段；所有未来可变字段使用可选值或忽略未知字段：

```swift
nonisolated internal struct HerdrSidebarSnapshot: Decodable, Equatable, Sendable {
  internal let version: String?
  internal let protocolVersion: UInt32?
  internal let focusedWorkspaceID: String?
  internal let focusedTabID: String?
  internal let focusedPaneID: String?
  internal let workspaces: [HerdrWorkspace]
  internal let tabs: [HerdrTab]
  internal let panes: [HerdrPane]
  internal let layouts: [HerdrLayout]
  internal let agents: [HerdrAgent]

  internal static let empty = Self(
    version: nil,
    protocolVersion: nil,
    focusedWorkspaceID: nil,
    focusedTabID: nil,
    focusedPaneID: nil,
    workspaces: [],
    tabs: [],
    panes: [],
    layouts: [],
    agents: []
  )
}

nonisolated internal struct HerdrWorkspace: Decodable, Equatable, Sendable, Identifiable {
  internal let workspaceID: String
  internal let number: Int?
  internal let label: String
  internal let focused: Bool
  internal let paneCount: Int?
  internal let tabCount: Int?
  internal let activeTabID: String?
  internal let agentStatus: String?

  internal var id: String { workspaceID }
}

nonisolated internal struct HerdrTab: Decodable, Equatable, Sendable, Identifiable {
  internal let tabID: String
  internal let workspaceID: String
  internal let number: Int?
  internal let label: String
  internal let focused: Bool
  internal let paneCount: Int?
  internal let agentStatus: String?

  internal var id: String { tabID }
}

nonisolated internal struct HerdrPane: Decodable, Equatable, Sendable, Identifiable {
  internal let paneID: String
  internal let terminalID: String?
  internal let workspaceID: String
  internal let tabID: String
  internal let focused: Bool
  internal let cwd: String?
  internal let foregroundCWD: String?
  internal let label: String?
  internal let agent: String?
  internal let title: String?
  internal let terminalTitle: String?
  internal let terminalTitleStripped: String?
  internal let displayAgent: String?
  internal let agentStatus: String?
  internal let tokens: [String: String]
  internal let revision: UInt64?

  internal var id: String { paneID }
  internal var isAgent: Bool { agent != nil }
}
```

`CodingKeys` 必须映射 snake_case，例如 `paneID = "pane_id"`、`terminalID = "terminal_id"`、`foregroundCWD =
"foreground_cwd"`。缺失的可选字段不得导致整个 snapshot decode 失败。

`HerdrAgent` 和 `HerdrLayout` 只建模 Sidebar 需要的字段；layout 首期只保存 `workspace_id`、`tab_id`、`focused_pane_id`
和 pane rect/split 数据，用于确认布局事件是否属于当前 session。不要复制 Herdr 完整 JSON schema。

所有 request/read failure 在进入 TCA State 前统一映射为以下 domain error；原始 errno、socket FD 和 `NSError` 不进入
`Equatable` state：

```swift
nonisolated internal enum HerdrSidebarFailure: Error, Equatable, Sendable {
  case unavailable
  case connection(HerdrSocketError)
  case invalidResponse(String)
  case server(code: String, message: String)
  case incompatibleProtocol
}
```

`HerdrSocketError.unsupportedProtocol` 和 `unsupportedResponseType` 映射为 `.incompatibleProtocol`；其它 socket
错误映射为 `.connection`，server error 保留 code/message 供日志和测试断言。

### 3.4 Response envelopes

新增明确的 response decoder：

```swift
nonisolated internal struct HerdrSnapshotResponse: Decodable, Sendable {
  internal let type: String
  internal let snapshot: HerdrSidebarSnapshot
}
```

要求 `type == "session_snapshot"` 且 `snapshot` 存在，否则抛出 `HerdrSocketError.unsupportedResponseType` 或
`invalidResponse`。错误 envelope 继续复用现有 `HerdrSocketError.serverError`。

### 3.5 Event stream

首期不需要解码完整事件 payload。`HerdrSocketClient.events()` 当前输出 `HerdrEventStreamState`，其中 `.event` 只
表示发生了变化；Sidebar 收到 `.event` 后重新请求完整 snapshot。这样可以避免丢事件字段导致本地 cache 错乱。

订阅列表必须是显式名称，不使用 wildcard：

```swift
private static let sidebarEventNames = [
  "workspace.created", "workspace.updated", "workspace.renamed", "workspace.moved",
  "workspace.closed", "workspace.focused",
  "tab.created", "tab.renamed", "tab.moved", "tab.closed", "tab.focused",
  "pane.created", "pane.updated", "pane.moved", "pane.focused", "pane.closed", "pane.exited",
  "layout.updated",
]
```

`pane.agent_status_changed`、`pane.scroll_changed`、`pane.output_matched` 是 pane-scoped；没有明确 pane id 时不订阅。

## 4. HerdrSidebarClient

新增 [HerdrSidebarClient.swift](/Users/yam/Developer/Prowl/supacode/Infrastructure/Herdr/HerdrSidebarClient.swift)。它是
TCA dependency，不直接持有 SwiftUI state：

```swift
internal struct HerdrSidebarClient: Sendable {
  internal var snapshot: @Sendable () async throws -> HerdrSidebarSnapshot
  internal var events: @Sendable () -> AsyncStream<HerdrEventStreamState>
  internal var focusWorkspace: @Sendable (String) async throws -> Void
  internal var focusTab: @Sendable (String) async throws -> Void
  internal var focusPane: @Sendable (String) async throws -> Void
}
```

实现规则：

- `snapshot()` 在每次调用中打开独立 socket，执行 protocol 已验证的 request，并在读取一行 response 后关闭。
- `events()` 打开独立长连接；订阅 ack 必须是 `subscription_started`，否则转成 `HerdrSocketError.unsupportedResponseType`。
- `focusWorkspace`、`focusTab`、`focusPane` 每次打开独立短连接，发送对应 method，成功 response 后关闭。
- 所有 request 的 `params` 即使为空也必须编码为 `{}`。
- 不在 client 层做 debounce、selection 或可见性决策。
- liveValue 复用当前 `HerdrSocketClient` 的 connect、timeout、SO_NOSIGPIPE、JSON line framing 和 protocol validation。
- testValue 允许注入 snapshot sequence、event stream、focus request recorder 和 deterministic failures。

推荐的 `DependencyKey` 形状：

```swift
extension HerdrSidebarClient: DependencyKey {
  static let liveValue = Self(...)
  static let testValue = Self(
    snapshot: { .empty },
    events: { AsyncStream { $0.finish() } },
    focusWorkspace: { _ in },
    focusTab: { _ in },
    focusPane: { _ in }
  )
}

extension DependencyValues {
  internal var herdrSidebarClient: HerdrSidebarClient {
    get { self[HerdrSidebarClient.self] }
    set { self[HerdrSidebarClient.self] = newValue }
  }
}
```

## 5. HerdrSidebarFeature

新增 [HerdrSidebarFeature.swift](/Users/yam/Developer/Prowl/supacode/Features/Clean/HerdrSidebarFeature.swift)。

### 5.1 State

```swift
@Reducer
internal struct HerdrSidebarFeature {
  @ObservableState
  internal struct State: Equatable {
    internal enum Connection: Equatable {
      case hidden
      case connecting
      case connected
      case failed
    }

    internal var connection: Connection = .hidden
    internal var snapshot: HerdrSidebarSnapshot = .empty
    internal var selectedWorkspaceID: String?
    internal var selectedTabID: String?
    internal var selectedPaneID: String?
    internal var pendingFocus: FocusTarget?
    internal var refreshGeneration: UInt64 = 0
    internal var isVisible: Bool { connection == .connected }
  }

  internal enum FocusTarget: Equatable, Sendable {
    case workspace(String)
    case tab(String)
    case pane(String)
  }

  internal enum Action: Equatable {
    case foregroundChanged(Bool)
    case snapshotResponse(Result<HerdrSidebarSnapshot, HerdrSidebarFailure>)
    case eventStream(HerdrEventStreamState)
    case debouncedRefresh
    case refreshResponse(Result<HerdrSidebarSnapshot, HerdrSidebarFailure>)
    case focusWorkspaceTapped(String)
    case focusTabTapped(String)
    case focusPaneTapped(String)
    case focusResponse(Result<Void, HerdrSidebarFailure>)
    case stop
  }
}
```

`HerdrSidebarFailure` 必须是 `Equatable, Sendable` 的 domain error，不把 `NSError` 或 raw socket FD 放入 State。

### 5.2 Lifecycle state machine

```text
hidden
  └─ foregroundChanged(true) -> connecting
       ├─ snapshot success -> connected + visible
       └─ snapshot failure -> hidden/failed retry policy

connected
  ├─ event -> debounce -> snapshot -> connected
  ├─ focus tap -> pendingFocus -> focus request -> snapshot
  ├─ stream disconnected -> reconnecting request -> snapshot
  └─ foregroundChanged(false) -> cancel tasks -> hidden

connecting/reconnecting
  ├─ success -> connected
  ├─ transient failure -> backoff retry while foreground remains true
  ├─ protocol incompatibility -> hidden + compatibility pause
  └─ foregroundChanged(false) -> hidden
```

### 5.3 Foreground start

`foregroundChanged(true)` 必须：

1. 取消上一次 Sidebar lifecycle task。
2. 将 state 设为 `.connecting`，清除旧 snapshot 的 visible selection，但保留 `pendingFocus = nil`。
3. 启动 `snapshot()` task。
4. snapshot 成功后启动 `events()` task；不要在 snapshot 失败时显示空 Sidebar。

`foregroundChanged(false)` 必须取消 snapshot、debounce、event stream 和 focus tasks，将 state 设为 `.hidden`，并清除
selection。它不应停止或重建 Ghostty surface。

### 5.4 Snapshot replacement

每次 snapshot 成功都原子替换整个 `snapshot`，不逐事件手动 patch workspace/tab/pane 数组。替换前执行 selection
reconciliation：

```swift
selectedWorkspaceID = snapshot.workspaces.contains { $0.id == selectedWorkspaceID }
  ? selectedWorkspaceID
  : snapshot.focusedWorkspaceID

selectedTabID = snapshot.tabs.contains { $0.id == selectedTabID }
  ? selectedTabID
  : snapshot.focusedTabID

selectedPaneID = snapshot.panes.contains { $0.id == selectedPaneID }
  ? selectedPaneID
  : snapshot.focusedPaneID
```

实际实现应使用 helper，避免 `nil` 的布尔表达式产生错误选择。server 的 focused IDs 是最终权威；用户点击后的
pending target 只有在 snapshot 确认存在时才转为 selected。

### 5.5 Event debounce

使用 `@Dependency(\.continuousClock) var clock`，固定 debounce 100ms。每个 event 只保留一个 pending refresh：

```swift
case .eventStream(.event):
  state.refreshGeneration &+= 1
  let generation = state.refreshGeneration
  return .run { send in
    try await clock.sleep(for: .milliseconds(100))
    guard !Task.isCancelled else { return }
    await send(.debouncedRefresh)
  }
  .cancellable(id: CancelID.refreshDebounce, cancelInFlight: true)
```

`debouncedRefresh` 请求 snapshot 时把 generation 带入 response action；响应 generation 不是当前值时直接丢弃，避免
旧查询覆盖新状态。实现中可以把 generation 包装在内部 response action，而不是让 network client 了解 TCA state。

### 5.6 Focus actions

点击 row 时不直接修改 server snapshot：

1. 设置 `pendingFocus`。
2. 调用对应 `HerdrSidebarClient` method。
3. request 成功后触发一次立即 snapshot，不等待下一次 event。
4. snapshot 中 `focused_*_id` 确认后更新 selected IDs，并清除 `pendingFocus`。
5. request 或刷新失败时清除 pending 状态，保持当前已确认 selection，并通过 `SupaLogger` 记录失败。

对于 `pane.focus`，普通 pane 和 Agent pane 使用同一 method；不调用 `agent.focus`，因为 Sidebar 的目标是任意 pane。

## 6. HerdrSidebarView

新增 [HerdrSidebarView.swift](/Users/yam/Developer/Prowl/supacode/Features/Clean/HerdrSidebarView.swift)。

### 6.1 Layout

```swift
internal enum HerdrSidebarLayout {
  internal static let width: CGFloat = 260
  internal static let minimumWidth: CGFloat = 220
  internal static let maximumWidth: CGFloat = 360
}
```

Sidebar 使用固定宽度约束，避免 snapshot 更新时 terminal surface 发生抖动。实现可在后续增加 user resize，但首期
不引入 divider drag state。

行分组：

1. Workspaces：按 snapshot `workspaces` 顺序显示。
2. Tabs/panes：按 workspace 分组；tab label 作为二级行，pane 作为 terminal row。
3. Agents：Agent pane 可以显示 `agent`、`display_agent`、`title`、`agent_status`；不创建第二份 Agent-only
   data source，直接从 `snapshot.panes` 关联 `snapshot.agents` 的 `pane_id`。
4. 普通 panes：`agent == nil`，显示 `label ?? terminal_title_stripped ?? foreground_cwd ?? pane_id`。

如果当前 snapshot 没有 Herdr pane，保持 Sidebar hidden/empty only according to connection state；不把 Prowl repository
empty state 组件放进来。

### 6.2 Interaction

- 每个 row 使用 `Button`，不使用 `onTapGesture` 修改 state。
- workspace、tab、pane row 分别发送 `.focusWorkspaceTapped`、`.focusTabTapped`、`.focusPaneTapped`。
- pending focus 显示轻量 selection state；request error 使用既有 Clean alert policy 或 row-level error text，不阻塞 terminal。
- 所有非显而易见图标按钮提供 `.help()` tooltip；使用 Dynamic Type，不复制 Standard Sidebar 的 custom color token。
- native Sidebar 可拥有自己的 scroll state，但 scroll 不写入 Herdr server，也不进入 Prowl persistence。

### 6.3 Terminal geometry

- Herdr inactive：Ghostty surface width 为全部 content width。
- Herdr active + snapshot connected：content width 减去 `HerdrSidebarLayout.width`，高度和 top chrome 规则保持现有 Clean。
- Sidebar show/hide 只改变 Clean content HStack，不改变 Ghostty surface identity，不创建新的 terminal surface。
- layout transition 必须在 main actor 执行；不在 socket background task 直接修改 view 或 Ghostty bridge。

## 7. Error and Reconnect Policy

### 7.1 Hidden before connection

- socket 文件不存在：不显示 Sidebar，保留输入法 adapter 的既有 retry。
- Herdr 进程已检测但 server 尚未 ready：Sidebar 进入 connecting，按 250ms、500ms、1s、2s 上限退避；仍不显示空面板。
- Herdr 不是 foreground：停止 Sidebar lifecycle，不因后台 Herdr server 仍在运行而显示 Sidebar。

### 7.2 Protocol incompatibility

`unsupportedProtocol` 或 `unsupportedResponseType`：

- 取消 Sidebar stream、snapshot 和 focus tasks。
- connection 置为 `.hidden`。
- 通过现有 Clean compatibility action 显示唯一兼容性 alert；不重复弹出 Sidebar 专属错误。
- 输入法 adapter 的兼容性行为保持当前实现，不被 Sidebar failure 改写。

### 7.3 Disconnect and stale responses

- event stream disconnect：不立即清空已确认 snapshot；设置 `.connecting`，启动 reconnect。
- reconnect 成功后先 snapshot，再恢复 event stream；期间 Sidebar 可以保持最后 snapshot 或隐藏，选择固定为隐藏以避免 stale
  state 被误认为实时状态。
- 每个 snapshot/focus response 携带 generation；generation 不匹配时丢弃。
- `foregroundChanged(false)` 后所有 task 必须取消；取消后的 response 不得重新显示 Sidebar。

### 7.4 Focus failures

- `not_found`：清除 pending target，立即 snapshot；如果 pane 已退出，selection fallback 到 server focused pane。
- `pane_focus_failed` 或 socket failure：保留旧 selection，记录 `SupaLogger`，不影响 terminal。
- server 返回未知 response type：按 protocol error 处理，不猜测 response shape。

## 8. File and Interface Map

### 8.1 Create

| File | Responsibility |
|---|---|
| `supacode/Features/Clean/HerdrSidebarFeature.swift` | TCA state/reducer/actions/lifecycle/reconnect/focus |
| `supacode/Features/Clean/HerdrSidebarView.swift` | SwiftUI layout、rows、selection、button interaction |
| `supacode/Infrastructure/Herdr/HerdrSidebarClient.swift` | TCA dependency、snapshot/events/focus closures、live/test values |

### 8.2 Modify

| File | Change |
|---|---|
| `supacode/Features/Clean/CleanAppFeature.swift` | Add `herdrSidebar` state/action scope and foreground delegate |
| `supacode/Features/Clean/CleanRootView.swift` | Scope Sidebar store and render optional HStack |
| `supacode/Features/Clean/CleanTerminalHost.swift` | Emit foreground Herdr transition callback |
| `supacode/App/supacodeApp.swift` | Inject Clean store callback/client and preserve Standard bootstrap |
| `supacode/Infrastructure/Herdr/HerdrSocketClient.swift` | Extract generic request/decode helpers without regressing input adapter |
| `supacode/Infrastructure/Herdr/HerdrWireModels.swift` | Add snapshot, pane, workspace, tab, layout, agent models |
| `supacode/Features/Clean/CleanAppFeatureTests.swift` or existing Clean test target | Reducer lifecycle and alert coverage |

### 8.3 Do not modify

- `supacode/Features/Repositories/` Sidebar and repository reducers
- `supacode/Features/Canvas/`, `Shelf/`, `Freestyle/`
- `WorktreeTerminalManager`, `TmuxTerminalController` and Standard layout persistence
- Herdr server source or Herdr protocol implementation
- Prowl CLI socket schema

## 9. Implementation Sequence

### Task 1: Wire model and client surface

**Files:** `HerdrWireModels.swift`, `HerdrSocketClient.swift`, new `HerdrSidebarClient.swift`.

- Add `HerdrSidebarSnapshot`, `HerdrWorkspace`, `HerdrTab`, `HerdrPane`, `HerdrAgent`, `HerdrLayout` Codable models.
- Add generic one-request decode for `session.snapshot`, `workspace.focus`, `tab.focus`, `pane.focus`.
- Keep existing `HerdrInputContextAdapter` behavior unchanged.
- Add test fixtures containing one Agent pane and one `agent == nil` pane.

### Task 2: Feature state and lifecycle

**Files:** new `HerdrSidebarFeature.swift`, `CleanAppFeature.swift`, existing Clean tests.

- Add state/action scope and foreground callback handling.
- Implement hidden/connecting/connected transitions.
- Implement snapshot replacement, generation checks, 100ms TestClock debounce and reconnect cancellation.
- Add reducer tests before implementation changes; use `TestStore` and injected `HerdrSidebarClient` test values.

### Task 3: Clean root layout

**Files:** `CleanRootView.swift`, `CleanTerminalHost.swift`, `supacodeApp.swift`.

- Wire `HerdrForegroundHandler` from terminal host to Clean store.
- Render only `HerdrSidebarView` when feature state is connected.
- Keep the existing Ghostty surface instance stable while sidebar width changes.
- Verify Herdr inactive remains full-bleed and Prowl original Sidebar remains absent.

### Task 4: Sidebar UI and actions

**Files:** new `HerdrSidebarView.swift`, feature tests, UI tests if present.

- Render workspace/tab/pane/agent rows from feature snapshot.
- Add ordinary pane rows based on `agent == nil`.
- Send focus actions and render pending/confirmed selection states.
- Add accessibility labels and tooltips for controls.

### Task 5: Integration and documentation

**Files:** Clean docs, project file if XcodeGen does not discover files, tests.

- Add snapshot/event/focus integration tests with fake socket client.
- Update `docs/components/clean-mode.md` only after behavior is implemented and verified.
- Preserve the original Clean Mode evaluation report as historical runtime design.

## 10. Test Matrix

### 10.1 Wire tests

- Decode snapshot with all arrays empty.
- Decode snapshot containing workspace, tab, Agent pane and non-Agent pane.
- Ignore unknown fields.
- Reject missing `session_snapshot` type or missing snapshot payload.
- Encode empty request params as `{}`.
- Record focus method names and target IDs.

### 10.2 Reducer tests

- `foregroundChanged(false)` never invokes socket client.
- `foregroundChanged(true)` requests snapshot before starting event consumption.
- Successful snapshot changes state to connected and makes Sidebar visible.
- Snapshot containing `agent == nil` produces a normal pane row.
- `.event` schedules exactly one debounced refresh for a burst of events.
- Old snapshot response with stale generation is ignored.
- Focus request success triggers immediate snapshot and eventually confirms selected ID.
- Focus request failure clears pending focus and preserves last confirmed selection.
- Event stream disconnect reconnects with exponential cap and does not duplicate tasks.
- Foreground false cancels all tasks and stale responses cannot re-show Sidebar.
- Protocol incompatibility hides Sidebar and emits one compatibility delegate action.

### 10.3 UI/layout tests

- Clean without Herdr renders terminal at full content width.
- Connected Herdr renders Sidebar at fixed width and terminal in remaining width.
- Sidebar visibility changes do not recreate Ghostty surface.
- Prowl Standard Sidebar is not present in Clean view hierarchy.
- Non-Agent pane row has no Agent-only status assumptions.
- Focused workspace/tab/pane selection uses server snapshot IDs.

### 10.4 Runtime verification

Run from `/Users/yam/Developer/Prowl` after implementation:

```bash
make check
make test
make install-dev-build
```

Manual runtime verification:

1. Start Prowl Clean with no Herdr foreground; confirm no Sidebar and full-width Ghostty shell.
2. Run `herdr` inside the shell; confirm one snapshot and native Sidebar appear.
3. Create a workspace/tab/pane in Herdr; confirm rows update without restarting Prowl.
4. Run a normal shell command in a pane; confirm it appears as non-Agent (`agent == nil`).
5. Click workspace, tab and pane rows; confirm Herdr focused IDs change and terminal client follows focus.
6. Stop Herdr; confirm Sidebar disappears and terminal returns to full width.
7. Restart Herdr server or break socket temporarily; confirm reconnect and no stale selection rollback.

## 11. Acceptance Criteria

The implementation is complete only when all of the following are true:

1. Clean Mode never mounts or depends on Prowl's original repository/worktree Sidebar.
2. Herdr foreground detection starts the Sidebar adapter only after a valid protocol check.
3. `session.snapshot` populates workspace, tab, pane, layout and agent state.
4. Both Agent and non-Agent panes appear with stable IDs and correct grouping.
5. Lifecycle/focus/layout events cause a debounced snapshot refresh.
6. Native Sidebar focus actions use Herdr JSON API and converge to server-confirmed selection.
7. No terminal stream or binary client protocol is required by this feature.
8. Herdr disconnect, protocol mismatch and exit do not break Ghostty input/rendering or input-source routing.
9. Standard Prowl runtime behavior and tests remain unchanged.
10. Clean user documentation describes the new Sidebar behavior after implementation verification.

## 12. Risks and Follow-up Boundary

- Herdr protocol version changes require updating the supported range and wire fixtures before enabling a new version.
- Snapshot replacement is intentionally authoritative; Sidebar does not attempt to replay every event locally.
- `pane.updated` is a state-change signal, not a terminal output stream. Terminal content takeover is a separate future spec.
- Native Sidebar dynamic visibility changes terminal geometry; verify resize, fullscreen, focus and mouse behavior separately.
- If Prowl later needs to render Herdr panes itself, create a separate technical spec for terminal stream ownership rather than
  expanding this Sidebar feature.
