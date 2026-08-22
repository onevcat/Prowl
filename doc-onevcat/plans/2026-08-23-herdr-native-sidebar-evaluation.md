# Prowl Clean Mode 的 Herdr Native Sidebar 扩展评估

日期：2026-08-23
状态：可行性评估

## 1. 结论

Prowl Clean Mode 已经隐藏 Prowl 原有的 repository/worktree Sidebar。本扩展不恢复、改造或复用那个
Sidebar，而是在 Clean root 中新增一个独立的 native `HerdrSidebarView`。

目标形态是：

```text
Clean root
└── Herdr active 时
    ├── Herdr native Sidebar（Prowl 自己的 SwiftUI/AppKit UI）
    └── 现有 Ghostty terminal surface（继续显示用户手动运行的 herdr client）
```

这个目标不需要实现 Herdr 的 terminal stream、ANSI frame bridge 或 binary client protocol。Prowl 现有
Ghostty surface 已经负责显示 Herdr client；native Sidebar 只需要读取 Herdr server 状态，并在点击时调用
workspace/tab/pane focus API。

## 2. 当前代码边界

Clean root 当前只渲染一个 Ghostty surface：

```swift
if let surface = terminalHost.surface {
  GhosttyTerminalView(surfaceView: surface)
}
```

见 [CleanRootView.swift](/Users/yam/Developer/Prowl/supacode/Features/Clean/CleanRootView.swift:4)。

Prowl 原有 Sidebar 位于 Standard `ContentView` 的 `NavigationSplitView` 中，见
[ContentView.swift](/Users/yam/Developer/Prowl/supacode/App/ContentView.swift:47)。Clean runtime 不挂载这个
View，因此新的 Sidebar 可以作为 Clean 专属 view 加入，不会与 Prowl repository/worktree state 耦合。

现有 [HerdrSocketClient.swift](/Users/yam/Developer/Prowl/supacode/Infrastructure/Herdr/HerdrSocketClient.swift:25)
已经具备：

- Unix socket 连接和超时
- `ping` protocol check
- `pane.current` 请求
- `events.subscribe` 长连接
- 断线状态和重连基础

现有 adapter 只服务输入法上下文，见
[HerdrInputContextAdapter.swift](/Users/yam/Developer/Prowl/supacode/Infrastructure/Herdr/HerdrInputContextAdapter.swift:40)。
Sidebar 不应把完整 session cache 塞进这个 adapter，而应使用独立的 `HerdrSidebarAdapter`，共享 socket
path、protocol validation 和 reconnect policy。

## 3. Herdr 数据和事件

### 3.1 首次快照

Sidebar adapter 连接后请求：

```json
{"id":"prowl-herdr-sidebar-snapshot","method":"session.snapshot","params":{}}
```

快照包含：

- `workspaces`
- `tabs`
- `panes`
- `layouts`
- `agents`
- `focused_workspace_id`
- `focused_tab_id`
- `focused_pane_id`

Herdr server 定义见 [session.rs](/Users/yam/Developer/herdr/src/api/schema/session.rs:8)。

### 3.2 Agent 与普通 pane

`agent.list` 只返回 Agent。普通 terminal 必须从 `session.snapshot.panes` 或 `pane.list` 获取。

Herdr 的 `PaneInfo` 同时提供：

```text
pane_id
terminal_id
workspace_id
tab_id
focused
cwd
foreground_cwd
label
agent
title
terminal_title
display_agent
agent_status
scroll
revision
```

普通 pane 的判定是 `agent == null`，不要用 `agent_status` 判定普通 shell 的业务状态。字段定义见
[panes.rs](/Users/yam/Developer/herdr/src/api/schema/panes.rs:397)。

### 3.3 实时事件

Sidebar 建立独立的 `events.subscribe` 长连接，逐项订阅：

```text
workspace.created / updated / renamed / moved / closed / focused
tab.created / renamed / moved / closed / focused
pane.created / updated / moved / focused / closed / exited
layout.updated
```

收到事件后短 debounce，再请求新的 `session.snapshot`，用完整快照替换本地 Sidebar model。这样可以覆盖
workspace、tab、pane 的创建、关闭、重命名、移动、焦点和布局变化，也能通过 `pane.updated` 刷新标题、metadata
和 Agent presentation。

`pane.agent_status_changed`、`pane.scroll_changed`、`pane.output_matched` 是带 `pane_id` 的 pane-scoped
subscription，不是无条件的全局事件。Sidebar 的全局刷新应依赖 `pane.updated` 与生命周期事件。事件定义见
[events.rs](/Users/yam/Developer/herdr/src/api/schema/events.rs:11)。

## 4. Native Sidebar 结构

推荐的 Clean root 结构：

```swift
HStack(spacing: 0) {
  if herdrSidebar.isVisible {
    HerdrSidebarView(model: herdrSidebar)
      .frame(width: 260)
  }

  GhosttyTerminalView(surfaceView: surface)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

可见性规则：

- 外层 foreground job 不是 `herdr` 时，不连接 Sidebar socket，Clean 保持原来的 full-bleed shell。
- 检测到 `herdr` 且首次 `session.snapshot` 成功后显示 Sidebar。
- Herdr 退出、socket 不可用或 protocol 不兼容时隐藏 Sidebar，terminal 恢复 full width。
- Sidebar adapter 错误不能影响 Ghostty surface 的输入、渲染或现有输入法 adapter。

`HerdrSidebarView` 只负责 SwiftUI rendering 和用户交互；`HerdrSidebarAdapter` 负责 socket、快照、事件和
focus action；两者不应放回 Standard `RepositoriesFeature` 或 Prowl 原有 Sidebar state。

## 5. Sidebar 交互

首期只使用 Herdr JSON API：

| 用户操作 | Herdr method |
|---|---|
| 聚焦 workspace | `workspace.focus` |
| 聚焦 tab | `tab.focus` |
| 聚焦 pane | `pane.focus` |
| 创建/关闭/重命名资源 | 对应 `workspace.*`、`tab.*`、`pane.*` method |
| 查看普通 pane 当前进程 | `pane.process_info` |

Prowl 不需要替换 Herdr client 的 terminal rendering。调用 `pane.focus` 后，Herdr 自己会在现有 Ghostty surface
内切换焦点，Prowl Sidebar 只需等待事件刷新选中状态。

## 6. 非目标

本扩展首期不包含：

- 复用 Prowl 原有 Sidebar 的 row model、repository/worktree reducer 或 action
- 接管 Herdr 的 PTY 或实现 `terminal attach`
- 解码 Herdr binary client protocol
- 自己渲染 Herdr 的 pane terminal 内容
- 自动启动、attach 或控制 Herdr server
- 把 Herdr workspace/tab/pane 持久化到 Prowl repository state

只有将来要求 Prowl 自己替代 Herdr client、直接承载 Herdr pane 画面时，才需要重新评估 terminal stream。

## 7. 预计改动

### 新增

| 路径 | 职责 |
|---|---|
| `supacode/Features/Clean/HerdrSidebarView.swift` | native Sidebar UI、row、分组和 focus action |
| `supacode/Features/Clean/HerdrSidebarFeature.swift` | Sidebar 状态、selection、可见性和错误状态 |
| `supacode/Infrastructure/Herdr/HerdrSidebarAdapter.swift` | `session.snapshot`、事件订阅、debounced refresh 和 JSON action |

### 修改

| 路径 | 修改 |
|---|---|
| `supacode/Features/Clean/CleanRootView.swift` | 在 Ghostty surface 旁挂载可选 Herdr Sidebar |
| `supacode/Features/Clean/CleanTerminalHost.swift` | 向 Sidebar adapter 转发 Herdr foreground/exit 生命周期 |
| `supacode/Infrastructure/Herdr/HerdrSocketClient.swift` | 增加 snapshot、focus request 和 Sidebar subscription 支持 |
| `supacode/Infrastructure/Herdr/HerdrWireModels.swift` | 增加 workspace/tab/pane/layout/agent snapshot models |
| `supacode/Features/Clean/CleanAppFeature.swift` | 若采用 TCA，承载 Sidebar delegate、alert 和 selection action |

## 8. 验证重点

- Clean 普通 shell 启动时不连接 Herdr socket。
- 手动输入 `herdr` 后完成 snapshot，显示新的 Herdr native Sidebar。
- Prowl 原 Sidebar、repository/worktree row 和 Standard reducer 没有被挂载。
- `snapshot.panes` 中 `agent == nil` 的普通 pane 能正确显示。
- pane/workspace/tab 创建、关闭、移动、聚焦和 `layout.updated` 能刷新 Sidebar。
- Sidebar 点击 focus 后，Herdr 的 `focused_pane_id` 与 native selection 最终一致。
- Herdr socket 断线重连后重新 snapshot，不用旧 response 覆盖新状态。
- Herdr 退出或 protocol 不兼容时 Sidebar 隐藏，Ghostty terminal 恢复 full width。
- Sidebar 错误不影响 terminal 输入、渲染和现有输入法切换。

## 9. 可行性结论

| 子目标 | 结论 |
|---|---|
| 隐藏 Prowl 原 Sidebar | 已由 Clean runtime 结构保证，不需要再复用或修改它 |
| 新增 Prowl native Herdr Sidebar | 可行，挂载到 `CleanRootView` 即可 |
| Agent 实时同步 | 可行，复用现有 Herdr socket/event 基础 |
| 非 Agent pane 同步 | 可行，使用 `session.snapshot.panes`/`pane.list`，不需要 Herdr server 改动 |
| Sidebar focus action | 可行，使用 `workspace.focus`、`tab.focus`、`pane.focus` |
| 首期是否需要 terminal stream | 不需要 |

原 Clean Mode 评估报告继续作为 Clean runtime 的基础设计和已完成验证记录；本文件只记录 Herdr native
Sidebar 扩展，不改变原报告内容。
