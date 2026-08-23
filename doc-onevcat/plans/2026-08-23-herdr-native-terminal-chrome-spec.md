# Prowl Clean Mode Herdr Native Terminal Chrome 技术 Spec

> 本文定义 Prowl Clean Mode 对 Herdr terminal chrome 的 native 实现，包括左侧 workspace/agent sidebar 和 terminal 顶部 tab bar。原有 [Herdr Native Sidebar 扩展评估](2026-08-23-herdr-native-sidebar-evaluation.md) 与 [Herdr Native Sidebar 技术 Spec](2026-08-23-herdr-native-sidebar-technical-spec.md) 保留作为历史基线；本文是后续 terminal chrome 实现的唯一执行 spec。

**日期：** 2026-08-23
**状态：** implementation spec
**目标：** 在 Prowl Clean Mode 中提供与 Herdr 自带 chrome 内容和交互一致、视觉更精致的 native terminal chrome。

## 1. 术语与命名

### 1.1 HerdrTerminalChrome

`HerdrTerminalChrome` 指 Prowl 为 Herdr session 提供的 native chrome，包含：

- workspace 与 agent sidebar；
- 当前 workspace 的 tab bar；
- 两者共享的 session snapshot、事件订阅、server selection reconciliation 和 mutation lifecycle。

### 1.2 Swift 类型命名

共享生命周期不再使用只表示 sidebar 的名称：

| 类型/文件 | 职责 |
|---|---|
| `HerdrTerminalChromeFeature` | TCA state、snapshot lifecycle、事件订阅、selection、focus 和 chrome mutation 状态 |
| `HerdrTerminalChromeClient` | Herdr JSON socket dependency，提供 snapshot、events、focus 和 tab/workspace mutation closures |
| `HerdrSessionSnapshot` | Herdr `session.snapshot` 的 wire model，包含 workspace、tab、pane、layout、agent |
| `HerdrSidebarView` | 左侧 sidebar 的纯 SwiftUI 子视图 |
| `HerdrTabBarView` | terminal 顶部 tab bar 的纯 SwiftUI 子视图 |
| `HerdrSidebarLayout` | sidebar 专属尺寸常量；不承担 terminal chrome feature 状态 |

`HerdrWireModels.swift` 中的通用 response envelope 可以继续使用现有命名；只有表达具体 session snapshot 的类型统一使用 `HerdrSessionSnapshot`。

## 2. 目标与约束

### 2.1 目标

1. 在 Clean Mode 中隐藏视觉上的 Herdr 原始 sidebar 和 tab bar，并显示 Prowl native chrome。
2. Native sidebar 的 workspace、agent、status dot、selection 和 focus 行为保持现有实现语义。
3. Native tab bar 的内容和交互与 Herdr 自带 tab bar 一致，同时使用更好的 macOS native spacing、hover、focus、overflow 和 context menu 表现。
4. Herdr server 继续是 session、tab 顺序、focused IDs、agent lifecycle 的唯一权威。
5. Herdr 退出、socket 断开或 protocol 不兼容时，native chrome 隐藏且 terminal 恢复可用状态。

### 2.2 约束

- 不恢复、修改或复用 Standard Mode 的 Prowl repository/worktree Sidebar。
- 不接管 Herdr PTY，不实现 Herdr binary client protocol，不自行渲染 terminal pane 内容。
- Herdr 侧增加 per-client `hide_navigation_chrome` handshake capability；该字段属于 binary client protocol 变更，Herdr protocol version 必须同步升级；该能力只影响声明了 native chrome 的 Herdr client。
- 不把 workspace、tab、pane、agent 持久化到 Prowl repository state。
- 不创建新的 Herdr session、workspace、pane 或 tab 用于验证；运行验证只读检查既有 session，除非测试使用 fake client。
- 所有 Herdr mutation 必须通过 JSON socket API；UI 不直接修改本地 snapshot 作为最终状态。
- 所有 socket、生命周期和 reducer 错误必须与 Ghostty terminal 输入、渲染、关闭和输入法 adapter 隔离。
- 使用 Swift 6.2、macOS 26、SwiftUI、The Composable Architecture、GhosttyKit、Unix domain socket、NDJSON 和 `SupaLogger`。

## 3. 视觉结构与 surface 几何

### 3.1 Native chrome occupies real layout space

Ghostty surface 保持一个稳定实例。Clean root 使用真实的 `HStack + VStack`，native sidebar 和 tab bar 占用自己的布局空间，Ghostty surface 被向下/向右挤开：

```swift
HStack(spacing: 0) {
  if store.herdrTerminalChrome.isVisible {
    HerdrSidebarView(
      store: store.scope(
        state: \.herdrTerminalChrome,
        action: \.herdrTerminalChrome
      )
    )
    .frame(width: HerdrSidebarLayout.width)
  }

  VStack(spacing: 0) {
    if store.herdrTerminalChrome.isVisible {
      HerdrTabBarView(
        store: store.scope(
          state: \.herdrTerminalChrome,
          action: \.herdrTerminalChrome
        )
      )
    }
    if let surface = terminalHost.surface {
      GhosttyTerminalView(surfaceView: surface)
    }
  }
  .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

真实布局的理由：

- native chrome 不遮挡 terminal pane 内容；
- Ghostty surface 的尺寸变化由真实 layout 传递给 surface，Herdr 会按新尺寸重新计算 pane；
- Herdr 原始 tab row 必须通过 client capability 隐藏，不能由 Prowl overlay 遮盖；
- sidebar 与 tab bar 的 hit testing 由 SwiftUI 原生 layout 处理。

Native chrome 使用自适应系统窗口背景色，避免下层 TUI 文字透出。tab bar 的高度必须作为 terminal surface 的真实 top inset。

### 3.2 Mouse event routing

`CleanTitlebarMouseForwarder` 只负责将属于 Ghostty surface 的 titlebar 事件转发给 surface。由于 native chrome 使用真实 layout，它不在 surface bounds 内，不需要额外的 overlay exclusion：

- surface bounds 只覆盖 terminal 内容区；
- tabbar、sidebar、context menu、rename sheet 和 confirmation alert 由 SwiftUI 接收；
- Ghostty 不会收到 native chrome 的 click/drag/scroll。

## 4. 数据模型

### 4.1 HerdrSessionSnapshot

`HerdrSessionSnapshot` 对应 `session.snapshot`：

```swift
nonisolated internal struct HerdrSessionSnapshot: Decodable, Equatable, Sendable {
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
}
```

所有字段保持向后兼容解码：可变或未来新增字段使用 optional，未知字段忽略；缺失数组按空数组处理。

### 4.4 Herdr 原始 tab 隐藏机制

当前 Herdr 只有 `hide_tab_bar_when_single_tab`，无法隐藏多 tab workspace 的原始 tab row，也没有 per-client 隐藏 sidebar 的能力。Prowl native chrome 采用真实布局后，不能通过遮罩解决重复渲染，因此需要 Herdr 增加 per-client capability：

1. Prowl Clean shell 为 Herdr client 注入 `PROWL_HERDR_NATIVE_CHROME=1`；
2. Herdr client 在 handshake 的 `Hello` 中携带 `hide_navigation_chrome=true`；
3. Herdr server 将 capability 保存在对应 `ClientConnection`，仅该 client 的 render path 隐藏 sidebar、跳过 tab row，并将 terminal area 从无 chrome 的区域开始布局；
4. 未携带 capability 的普通 Herdr client 继续使用原有 tab bar；
5. protocol version 升级后，旧 client/server 按现有版本协商拒绝连接，不允许静默解释不兼容的 bincode payload。

这项 Herdr-side extension 是 Prowl native tabbar 正确替换原 tab row 的前置条件；在它可用前，Prowl 不应宣称已经完成无重复 chrome 的最终体验。

### 4.2 Tab 展示模型

Native tab bar 只展示 Herdr 自带 tab bar 的内容元素：

- `HerdrTab.label`：tab label；
- zoom 状态：在 `HerdrSessionSnapshot.layouts` 中查找相同 `workspace_id` + `tab_id` 的 `zoomed`；为 true 时在 label 后追加 ` Z`；
- active 状态：使用 `focusedTabID` 与 tab ID 比较；不以本地点击状态作为最终权威；
- server 顺序：使用 snapshot.tabs 返回顺序，不按本地标题排序。

不把 `agent_status`、pane 数量或额外 badge 添加到 tab label 内，因为这些不是 Herdr 原始 tab bar 的内容元素。Agent 状态继续显示在 sidebar 的 agent rows。

### 4.3 状态与 selection

`HerdrTerminalChromeFeature.State` 统一持有：

- `connection`：hidden / connecting / connected / failed；
- `snapshot`：`HerdrSessionSnapshot`；
- `selectedWorkspaceID`、`selectedTabID`、`selectedPaneID`：由 server focused IDs reconciliation 得到；
- `pendingFocus`：等待 server 确认的 focus target；
- `pendingMutation`：create / rename / move / close 的 request 状态；
- `mutationError`：可展示给 native UI 的 domain error；
- `refreshGeneration`：丢弃旧 snapshot/response；
- `subscribedPaneIDs`：用于动态 pane-specific agent status subscriptions。

`selectedTabID` 与 `focusedTabID` 不一致时，tab bar 保留 server snapshot 的 active 样式；pending 状态只用于禁用重复操作和显示短暂 busy affordance。

## 5. HerdrTerminalChromeFeature

### 5.1 Lifecycle

- Clean foreground process 确认是 `herdr` 后，发送 `foregroundChanged(true)`；
- feature 请求 `ping` protocol check，再请求 `session.snapshot`；
- snapshot 成功后进入 `.connected`，sidebar 和 tab bar 同时可见；
- 根据 snapshot pane IDs 建立全局 lifecycle 与动态 pane-specific event subscription；
- 收到事件后 100ms debounce，再请求完整 snapshot；
- Herdr 退出或 `foregroundChanged(false)` 时取消 lifecycle、refresh、focus、mutation tasks，清空 snapshot 并隐藏 chrome；
- 普通 shell、socket 不存在或 Herdr 不在 foreground 时，不显示 stale chrome。

### 5.2 Action 分类

```swift
internal enum Action: Equatable {
  case foregroundChanged(Bool)
  case snapshotResponse(Result<HerdrSessionSnapshot, HerdrTerminalChromeFailure>)
  case eventStream(HerdrEventStreamState)
  case debouncedRefresh
  case refreshResponseWithGeneration(
    UInt64,
    Result<HerdrSessionSnapshot, HerdrTerminalChromeFailure>
  )
  case focusWorkspaceTapped(String)
  case focusTabTapped(String)
  case focusPaneTapped(String)
  case newTabSubmitted(workspaceID: String, label: String?)
  case renameTabSubmitted(tabID: String, label: String)
  case moveTabSubmitted(tabID: String, insertIndex: Int)
  case closeTabTapped(tabID: String, workspaceID: String, isLastTab: Bool)
  case closeWorkspaceConfirmed(String)
  case mutationResponse(HerdrTerminalChromeFeature.MutationResult)
  case focusResponse(FocusResult)
  case delegate(DelegateAction)
  case stop
}
```

具体枚举可以按现有 reducer 风格拆分，但必须保留上述行为边界：view 只发意图，client 执行 API，snapshot/event 最终确认状态。

### 5.3 Stale response

- 每次 foreground transition、disconnect、refresh burst 和 mutation request 都更新 generation 或 request token；
- response token 与当前 state 不匹配时直接丢弃；
- `foregroundChanged(false)` 后到达的 response 不能重新显示 chrome；
- mutation 成功后不直接拼接本地 snapshot，等待 Herdr event + snapshot；
- focus/mutation 的 `not_found` 必须触发一次新 snapshot，并清除对应 pending target。

## 6. HerdrTerminalChromeClient 与 JSON API

### 6.1 Client interface

```swift
nonisolated internal struct HerdrTerminalChromeClient: Sendable {
  internal var snapshot: @Sendable () async throws -> HerdrSessionSnapshot
  internal var events: @Sendable (Set<String>) -> AsyncStream<HerdrEventStreamState>
  internal var focusWorkspace: @Sendable (String) async throws -> Void
  internal var focusTab: @Sendable (String) async throws -> Void
  internal var focusPane: @Sendable (String) async throws -> Void
  internal var createTab: @Sendable (String, String?, String?) async throws -> Void
  internal var renameTab: @Sendable (String, String) async throws -> Void
  internal var moveTab: @Sendable (String, Int) async throws -> Void
  internal var closeTab: @Sendable (String) async throws -> Void
  internal var closeWorkspace: @Sendable (String) async throws -> Void
}
```

所有 live/test dependency 都必须实现完整 interface。test value 记录调用参数，不访问真实 Herdr socket。

### 6.2 API mapping

| Native action | Herdr method | 参数 |
|---|---|---|
| workspace focus | `workspace.focus` | `workspace_id` |
| tab focus | `tab.focus` | `tab_id` |
| pane focus | `pane.focus` | `pane_id` |
| create tab | `tab.create` | `workspace_id`、`focus=true`、可选 `label`；context menu New tab 先 focus 来源 tab |
| rename tab | `tab.rename` | `tab_id`、`label` |
| move tab | `tab.move` | `tab_id`、`insert_index` |
| close tab | `tab.close` | `tab_id` |
| close last tab after confirmation | `workspace.close` | `workspace_id` |

每个普通 request 使用独立 Unix socket connection；`events.subscribe` 使用独立长连接。现有 protocol check、timeout、line length 和 error mapping 继续复用。

### 6.3 Close confirmation

Herdr `tab.close` 在关闭 workspace group 需要确认时返回 `confirmation_required`。Native flow：

1. 用户在 context menu 选择 Close；
2. client 请求 `tab.close`；
3. server 返回 `confirmation_required` 时，feature 显示 native confirmation；
4. 用户确认后调用 `workspace.close`；
5. 用户取消则清除 pending mutation，不改变 snapshot；
6. 其它 `not_found`、socket failure 或 protocol failure 按普通 mutation error 处理，不自动重试破坏性操作。

## 7. HerdrTabBarView

### 7.1 Layout

- 高度固定，建议 `28...34pt`，以系统 titlebar/toolbar 的视觉密度为基准；
- 背景使用与 Clean sidebar 一致的 material/tint；
- tab item 保持稳定的 min width、padding 和 close/drag hit area；
- tabs 太多时使用横向 ScrollView，active tab 变化时滚动到可见区域；
- overflow controls 使用 icon-only button，并提供 tooltip/accessibility label；
- `+` 为 icon button，不使用圆角文字按钮；
- native tab bar 不改变 Ghostty surface frame。

### 7.2 Tab item

每个 tab item 包含：

- label；
- zoom suffix `Z`（仅当对应 layout.zoomed）；
- active/inactive background 和 foreground；
- hover/pressed/dragging visual state；
- close affordance 可以在 hover 时出现，但不能替代右键 context menu；
- accessibility label 使用完整展示 label，并注明 active/zoom 状态。

不添加 Herdr 原始 tab bar 没有的 agent status text 或 pane tree。

### 7.3 Interactions

| 手势/操作 | 行为 |
|---|---|
| 左键单击 tab | `tab.focus`，等待 server focused tab 确认 |
| tab bar 滚轮 | 按 snapshot tabs 顺序循环 focus previous/next tab |
| tab 横向滚动 | overflow 时移动 native tab viewport，不改变 server tab 顺序 |
| 左键拖拽 tab | 计算 insert index，调用 `tab.move`；显示 drop indicator |
| 点击 `+` | 显示 native tab name prompt；提交后 `tab.create` |
| 右键 tab | 显示 New tab / Rename / Close |
| 右键菜单 New tab | 以该 tab 所属 workspace 创建并 focus 新 tab |
| 右键菜单 Rename | 预填当前 label，提交 `tab.rename` |
| hover close | 关闭对应 tab；同样走 confirmation/error flow |

Native tab bar 的交互结果不得只更新 local ordering 或 selected ID；必须最终以 Herdr snapshot 回填。

## 8. Sidebar 子视图

`HerdrSidebarView` 继续保留 sidebar 专属命名和职责：

- workspace rows：workspace label、tab/pane summary、focused/selected state；
- agent rows：agent title、workspace/tab subtitle、working/blocked/done/idle/unknown marker；
- `done` 实心大点表示未读，`idle` 空心大点表示已读，`unknown` 小点；
- workspace/tab/pane focus 通过 `HerdrTerminalChromeFeature.Action` 发出；
- sidebar 不直接调用 `HerdrTerminalChromeClient`。

## 9. 错误与可见性

### 9.1 Error mapping

统一使用 `HerdrTerminalChromeFailure`：

- `.unavailable`：socket 不存在、拒绝连接；
- `.connection(HerdrSocketError)`：其它连接/读写错误；
- `.invalidResponse(String)`：JSON 或 response shape 无效；
- `.server(code:message:)`：Herdr server error；
- `.incompatibleProtocol(HerdrSocketError)`：protocol/version/response type 不兼容。

### 9.2 UI behavior

- unavailable/disconnected：进入 connecting/retry，不能把旧 selection 当作实时确认；
- incompatible protocol：隐藏 chrome，并沿用现有 Clean compatibility alert；
- mutation error：保留当前 confirmed snapshot，显示局部错误，不影响 terminal；
- close confirmation：只有明确用户确认后才执行 workspace close；
- Herdr foreground 变为 false：取消所有 tasks，隐藏 sidebar 与 tab bar。

## 10. 文件与职责

### 10.1 Existing rename

| 原路径 | 新路径 |
|---|---|
| `supacode/Features/Clean/HerdrSidebarFeature.swift` | `supacode/Features/Clean/HerdrTerminalChromeFeature.swift` |
| `supacode/Infrastructure/Herdr/HerdrSidebarClient.swift` | `supacode/Infrastructure/Herdr/HerdrTerminalChromeClient.swift` |
| `supacodeTests/HerdrSidebarTests.swift` | `supacodeTests/HerdrTerminalChromeTests.swift` |

### 10.2 New/modified files

| 路径 | 职责 |
|---|---|
| `supacode/Features/Clean/HerdrTabBarView.swift` | tab bar rendering、viewport、hover、drag、context menu |
| `supacode/Features/Clean/HerdrSidebarView.swift` | sidebar rendering；继续保留 sidebar 子视图命名 |
| `supacode/Features/Clean/HerdrTerminalChromeFeature.swift` | shared TCA state/reducer/lifecycle/focus/mutation |
| `supacode/Infrastructure/Herdr/HerdrTerminalChromeClient.swift` | shared dependency and API closures |
| `supacode/Infrastructure/Herdr/HerdrSocketClient.swift` | tab/workspace request encoding、response/error decoding、event subscription |
| `supacode/Infrastructure/Herdr/HerdrWireModels.swift` | `HerdrSessionSnapshot` 与 tab/layout models |
| `supacode/Features/Clean/CleanAppFeature.swift` | `herdrTerminalChrome` scope 和 lifecycle delegate |
| `supacode/Features/Clean/CleanRootView.swift` | 真实 HStack/VStack layout 与 native chrome composition |
| `supacodeTests/HerdrTerminalChromeTests.swift` | reducer、wire、mutation、stale response tests |
| `supacodeTests/HerdrTabBarViewTests.swift` | pure tab projection、zoom label、order、insert index、wheel cycle tests |

### 10.3 Herdr-side prerequisite

| 路径 | 职责 |
|---|---|
| `herdr/src/protocol/wire.rs` | 为 `ClientMessage::Hello` 增加 `hide_navigation_chrome` 字段并升级 protocol |
| `herdr/src/client/mod.rs` | 根据 `PROWL_HERDR_NATIVE_CHROME` 设置 handshake capability |
| `herdr/src/server/clients.rs` | 保存 client-local hide navigation chrome capability |
| `herdr/src/server/headless.rs` / `herdr/src/ui.rs` | 仅对 capability client 隐藏 sidebar 与 tab row |

不修改 Standard `RepositoriesFeature`、Standard Sidebar、Canvas、Shelf、Freestyle、Herdr server source或 Prowl CLI schema。

## 11. 实现阶段与提交边界

建议按以下逻辑拆分，避免把 protocol、TCA、UI 和 geometry 混在一个大 commit：

1. 命名整理：完成 `HerdrTerminalChromeFeature`、`HerdrTerminalChromeClient`、`HerdrSessionSnapshot` 的迁移并保持现有 sidebar 测试通过；
2. client/API：增加 tab/workspace mutation request、response 和 error mapping；
3. feature：增加 mutation state、confirmation flow、generation/stale response tests；
4. tab bar projection/UI：实现 label/zoom/order、focus、create、rename、close、drag 和 overflow；
5. Clean layout：使用真实 HStack/VStack，让 native tabbar 挤开 Ghostty surface；
6. Herdr capability：完成 per-client hide tab row 后再进行最终集成验证；
7. 集成验证：定向测试、Debug build/install、截图和只读 session 核对。

每个 commit 使用 lowercase conventional commit，提交前先确认 commit message；不 push `origin` 或 `upstream`。

## 12. 验收标准

### 12.1 内容

- 当前 focused workspace 的 tab 顺序、label、zoom `Z` 与 Herdr snapshot 一致；
- workspace/sidebar 与 tab bar 的 active selection 最终由 server focused IDs 确认；
- 不出现额外的 agent status/pane tree 内容污染 tab item。

### 12.2 交互

- 点击 tab 能切换 Herdr session focused tab；
- tab bar 滚轮能循环切换 tabs；
- tab 可拖拽排序，重连或 refresh 后顺序不回退；
- `+`、Rename、Close 和 context menu 均可用；
- close confirmation 取消不会关闭 workspace，确认后 server 状态正确刷新；
- socket/event 断线期间不会接受过期 response 覆盖当前状态。

### 12.3 视觉与布局

- native sidebar 和 native tab bar 不显示下层 Herdr TUI chrome；
- Ghostty surface 按真实 native chrome 高度/宽度重新布局，不发生遮罩裁切；
- native chrome 的点击、拖拽、滚轮不会被 Ghostty 转发器吞掉；
- inactive window、窄窗口、tabs overflow、长 label 和高对比/浅色外观下没有文字重叠或裁切；
- 原有 Prowl Standard UI 不被 Clean chrome 改动。

### 12.4 验证命令

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project supacode.xcodeproj \
  -scheme supacode \
  -destination 'platform=macOS' \
  -only-testing:supacodeTests/HerdrTerminalChromeTests

make install-dev-build
git diff --check
```

完整测试中与本功能无关的既有超时或环境失败必须单独记录；不能把全量测试失败误报为 terminal chrome 失败。

## 13. 非目标

- 不实现 Herdr terminal stream 或 Prowl 自己的 pane renderer；
- 不改变 Herdr server 的全局 sidebar/tab 配置；隐藏 tab 只通过 per-client capability 生效；
- 不在 Prowl 中复制 Herdr 的 workspace/tab/pane 持久化模型；
- 不自动创建、关闭、重命名或 focus Herdr 资源作为截图验证步骤；
- 不修改旧评估报告和旧 sidebar spec 的历史内容。
