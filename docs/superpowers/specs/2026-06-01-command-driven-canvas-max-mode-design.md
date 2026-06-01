# Command-driven Canvas Max Mode 设计

## 背景

Canvas max mode 已经能把当前卡片放大，并通过 Ghostty binding action 临时增大字体。当前入口集中在 `CanvasView`：

`supacode/Features/Canvas/Views/CanvasView.swift:1332`

```swift
private func toggleCanvasMaxMode() {
  if maximizedCanvasTabID != nil {
    restoreMaxModeFontBoost()
    maximizedCanvasTabID = nil
    return
  }

  let states = terminalManager.activeWorktreeStates
  let tabs = visibleCanvasTabs(from: states)
  guard let current = currentCanvasTab(from: tabs) else { return }
  maximizedCanvasTabID = current.tabID
  applyMaxModeFontBoost(to: current.tabID, states: states)
}
```

这对 `lazygit`、`lazydocker`、`btop` 这类全屏 TUI 很有价值：它们在普通 Canvas 卡片里布局太小，进入 max mode 后可读性明显更好。

但实现不能写成命令名特判，例如：

```swift
if progressName == "lazygit" {
  triggerMaxMode()
}
```

原因是这会把 UI 行为绑定到单个命令，也难以扩展到其他 TUI、用户自定义命令或未来的规则配置。

## 目标

1. 根据命令或前台进程自动触发 Canvas max mode。
2. 自动进入和自动退出必须能独立控制。
3. 不影响现有 tab icon 自动检测行为。
4. 不把 `lazygit` 写成业务逻辑分支；它只能作为一条数据规则存在。
5. 用户手动 max mode 的行为优先于自动策略。

## 非目标

1. 第一阶段不做复杂规则编辑器。
2. 不改变 Ghostty 本身的 action 语义。
3. 不把所有命令都做自动 layout 分类；只支持明确配置过的命令。
4. 不用 viewport 文本内容猜测 TUI 类型，避免误判。

## 现有信号

### 命令标题

Ghostty bridge 已经能收到 shell integration 设置的 title：

`supacode/Infrastructure/Ghostty/GhosttySurfaceBridge.swift:203`

```swift
case GHOSTTY_ACTION_SET_TITLE:
  if let title = string(from: action.action.set_title.title) {
    state.title = title
    onTitleChange?(title)
  }
  return true
```

`WorktreeTerminalState` 目前用这个 title 做 icon detection：

`supacode/Features/Terminal/Models/WorktreeTerminalState.swift:2076`

```swift
func noteTitleForCommandDetection(_ rawTitle: String, surfaceId: UUID, tabId: TerminalTabID) {
  let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !title.isEmpty else { return }
  if Self.isLikelyIdleTitleByShape(title) { return }
  if learnedIdleTitlesBySurface[surfaceId]?.contains(title) == true { return }
  guard let icon = CommandIconMap.iconForFirstToken(title) else { return }
  applyResolvedIcon(icon, surfaceId: surfaceId, tabId: tabId)
}
```

这个信号适合做自动进入，因为响应快，通常在命令刚开始时就能拿到。

### 命令结束

Ghostty bridge 已经能收到 command finished：

`supacode/Infrastructure/Ghostty/GhosttySurfaceBridge.swift:268`

```swift
case GHOSTTY_ACTION_COMMAND_FINISHED:
  let info = action.action.command_finished
  let exitCode = info.exit_code == -1 ? nil : Int(info.exit_code)
  onCommandFinished?(exitCode, info.duration)
  return true
```

这个信号适合做部分自动退出，但不应该是唯一退出依据。全屏 TUI 有时会修改标题，tmux 场景下 title 和真实前台进程也可能不完全同步。

### 前台进程

Prowl 已经能从 Ghostty surface 拿 foreground process group，并解析前台 job：

`supacode/Infrastructure/Ghostty/GhosttySurfaceBridge.swift:71`

```swift
func foregroundProcessGroupID() -> pid_t? {
  guard let surface else { return nil }
  let processGroupID = ghostty_surface_foreground_process_group(surface)
  return processGroupID > 0 ? pid_t(processGroupID) : nil
}
```

`supacode/Infrastructure/AgentDetection/ProcessDetection.swift:74`

```swift
static func foregroundJob(processGroupID: pid_t) -> ForegroundJob? {
  let processes = processGroupPIDs(processGroupID).compactMap { pid -> ForegroundProcess? in
    let argv = processArguments(pid: pid)
    return ForegroundProcess(
      pid: pid,
      name: name,
      argv0: argv?.first.flatMap(basename),
      cmdline: argv?.joined(separator: " ")
    )
  }

  guard !processes.isEmpty else { return nil }
  return ForegroundJob(processGroupID: processGroupID, processes: processes)
}
```

这个信号适合确认“当前前台程序仍然是某条规则命中的程序”，也适合支持 `onForegroundProcessExit` 退出策略。

## 设计概述

新增一条独立于 icon 的 presentation policy 管线：

```text
Ghostty title / foreground job
        ↓
CommandPresentationPolicy
        ↓
CommandPresentationIntent
        ↓
TerminalClient.Event
        ↓
CanvasView applies or restores auto max mode
```

icon 继续走 `CommandIconMap`。max mode 自动策略走新的 `CommandPresentationPolicy`。两个系统只共享命令 token 解析，不共享规则表。

## 数据模型

### 命令匹配

```swift
enum CommandPresentationMatcher: Equatable, Sendable {
  case firstToken(String)
  case executableName(String)
}
```

第一阶段只需要 `firstToken` 和 `executableName`。不急着支持 regex，避免配置能力过强导致误判和 UI 复杂度上升。

### presentation 行为

```swift
enum CommandPresentationAction: Equatable, Sendable {
  case canvasMaxMode
}
```

第一阶段只有 `canvasMaxMode`。以后可以扩展到其他 presentation 行为，例如自动切到 Canvas、自动聚焦某个 pane，但不在本次设计范围内。

### 自动进入策略

```swift
enum CommandPresentationEntryPolicy: Equatable, Sendable {
  case disabled
  case whenMatched
}
```

`disabled` 表示命中规则也不自动进入。这样用户可以保留规则，但临时关闭自动进入。

### 自动退出策略

```swift
enum CommandPresentationExitPolicy: Equatable, Sendable {
  case manual
  case onCommandFinished
  case onForegroundProcessExit
}
```

含义：

- `manual`：只自动进入，不自动退出。用户手动退出 max mode。
- `onCommandFinished`：收到 Ghostty command finished 后，如果当前 max mode 是这条规则自动进入的，则自动退出。
- `onForegroundProcessExit`：轮询或复用现有前台进程检测，当匹配进程不再是 foreground job 时自动退出。

新诉求“有时我只想进入，不想进程退出时也跟着退出”对应 `entryPolicy = .whenMatched` 且 `exitPolicy = .manual`。

### 规则

```swift
struct CommandPresentationRule: Equatable, Sendable {
  var matcher: CommandPresentationMatcher
  var action: CommandPresentationAction
  var entryPolicy: CommandPresentationEntryPolicy
  var exitPolicy: CommandPresentationExitPolicy
}
```

内建规则可以是数据，而不是代码分支：

```swift
static let builtInRules: [CommandPresentationRule] = [
  CommandPresentationRule(
    matcher: .firstToken("lazygit"),
    action: .canvasMaxMode,
    entryPolicy: .whenMatched,
    exitPolicy: .manual
  ),
  CommandPresentationRule(
    matcher: .firstToken("lazydocker"),
    action: .canvasMaxMode,
    entryPolicy: .whenMatched,
    exitPolicy: .manual
  ),
]
```

默认 `exitPolicy` 建议先用 `.manual`。这更保守，不会在 TUI 退出后突然改变用户当前布局。后续如果体验确认稳定，再考虑把部分内建规则改成 `onForegroundProcessExit`。

### 自动 max mode 状态

Canvas 需要记录这次 max mode 是用户手动触发还是策略自动触发：

```swift
struct AutoCanvasMaxModeSession: Equatable {
  var surfaceID: UUID
  var tabID: TerminalTabID
  var matcherDescription: String
  var exitPolicy: CommandPresentationExitPolicy
  var suppressUntilCommandFinished: Bool
}
```

规则：

1. 用户手动进入 max mode 时，不创建 `AutoCanvasMaxModeSession`。
2. 自动进入 max mode 时，创建 session。
3. 用户手动退出自动 max mode 时，清理 session，并对当前 command 做 suppress，防止下一次检测立即又打开。
4. 自动退出只允许退出当前 session 负责的 max mode，不能关闭用户手动打开的 max mode。

## 与 icon 检测的关系

现有 icon 检测入口不应该被 presentation 策略接管。建议只提取一个共享 token parser：

```swift
enum CommandToken {
  static func firstToken(of title: String) -> String {
    title
      .split(separator: " ", omittingEmptySubsequences: true)
      .first
      .map(String.init)
      ?? title
  }
}
```

`CommandIconMap` 保持自己的规则表：

```swift
static func iconForFirstToken(_ title: String) -> TabIconSource? {
  let token = CommandToken.firstToken(of: title).lowercased()
  return firstTokenMapping[token]
}
```

新的 presentation policy 使用自己的规则表：

```swift
static func rule(forTitle title: String) -> CommandPresentationRule? {
  let token = CommandToken.firstToken(of: title).lowercased()
  return rules.first { $0.matches(firstToken: token) }
}
```

`WorktreeTerminalState.noteTitleForCommandDetection` 需要避免继续用 icon 的 `guard` 截断流程。目标形态：

```swift
if let icon = CommandIconMap.iconForFirstToken(title) {
  applyResolvedIcon(icon, surfaceId: surfaceId, tabId: tabId)
}

if let rule = CommandPresentationPolicy.rule(forTitle: title) {
  onCommandPresentationIntent?(.matched(rule), surfaceId, tabId)
}
```

这样没有 icon 的命令仍然可以触发 presentation，已有 icon 自动检测也不会被 max mode 规则影响。

## 事件流

### 自动进入

1. Ghostty 收到 `GHOSTTY_ACTION_SET_TITLE`。
2. `WorktreeTerminalState.noteTitleForCommandDetection` 过滤 idle prompt。
3. `CommandPresentationPolicy` 根据 title 匹配规则。
4. 如果规则的 `entryPolicy == .whenMatched`，发出 `CommandPresentationIntent`。
5. `WorktreeTerminalManager` 转成 `TerminalClient.Event`。
6. `CanvasView` 收到事件：
   - 如果当前不在 Canvas，忽略或延迟处理。第一阶段建议忽略。
   - 如果当前已经是用户手动 max mode，忽略。
   - 如果当前是其他自动 max mode，按焦点和 surfaceID 决定是否切换。第一阶段建议不切换。
   - 如果当前无 max mode，进入当前匹配 tab 的 max mode。

### 自动退出

`exitPolicy == .manual`：

1. 不监听命令结束来退出。
2. 用户按现有快捷键或 toolbar 退出。

`exitPolicy == .onCommandFinished`：

1. Ghostty 收到 `GHOSTTY_ACTION_COMMAND_FINISHED`。
2. `WorktreeTerminalState` 发出 command finished 事件。
3. Canvas 检查当前 `AutoCanvasMaxModeSession.surfaceID` 是否一致。
4. 一致则退出自动 max mode。

`exitPolicy == .onForegroundProcessExit`：

1. 自动进入后启动轻量检测任务，周期复用现有 foreground job probe。
2. 如果 foreground job 不再包含匹配 executable，退出自动 max mode。
3. 如果 surface 关闭、tab 关闭、Canvas 消失，也清理 session。

## 设置策略

第一阶段可以不做完整规则编辑器，但需要保留数据结构能表达独立开关。

建议的最小设置：

```swift
struct CommandPresentationSettings: Codable, Equatable, Sendable {
  var isEnabled: Bool
  var defaultExitPolicy: CommandPresentationExitPolicy
}
```

默认值：

```swift
CommandPresentationSettings(
  isEnabled: true,
  defaultExitPolicy: .manual
)
```

内建规则如果没有显式 exit policy，则使用 `defaultExitPolicy`。这样用户可以全局选择：

- 自动进入，手动退出。
- 自动进入，命令结束后退出。
- 完全关闭自动进入。

如果后续要支持每条命令单独控制，再扩展为：

```swift
struct UserCommandPresentationOverride: Codable, Equatable, Sendable {
  var matcher: CommandPresentationMatcher
  var entryPolicy: CommandPresentationEntryPolicy
  var exitPolicy: CommandPresentationExitPolicy
}
```

## UI 入口

第一阶段建议放在 Settings 的 Canvas 或 Terminal 区域，避免把这个行为藏在快捷键设置里。

控件：

1. Toggle: `Automatically enter Canvas Max Mode for full-screen terminal apps`
2. Picker: `When the command exits`
   - `Stay in Max Mode`
   - `Exit Max Mode`

如果第一阶段不做 UI，也可以先用默认内建行为和 settings file 字段，但需要保证 decode 缺省值稳定。

## 边界行为

1. 用户手动打开 max mode 后，命令规则不接管退出。
2. 用户手动退出自动 max mode 后，同一条 running command 不再自动打开。
3. 普通 worktree detail 模式不自动切换到 Canvas。第一阶段只在 Canvas 已打开时生效。
4. split tab 中只对当前 focused surface 生效，避免后台 split 抢当前卡片。
5. 如果 tab 或 surface 被关闭，自动 session 必须清理。
6. 如果 Canvas view disappear，沿用现有 `restoreMaxModeFontBoost()`，并清理自动 session。

## 测试计划

### Policy 单元测试

覆盖：

1. `lazygit` title 命中 `.canvasMaxMode`。
2. 大小写不敏感。
3. 未配置命令不命中。
4. icon map 未命中时，presentation policy 仍可命中。
5. `entryPolicy = .disabled` 时不生成进入 intent。
6. `exitPolicy = .manual` 时 command finished 不生成退出 intent。

### WorktreeTerminalState 测试

覆盖：

1. title 命中 icon 和 presentation 时，两者都执行。
2. title 只命中 presentation、不命中 icon 时，仍发出 presentation intent。
3. idle prompt 不触发 presentation。
4. learned idle title 不触发 presentation。

### CanvasView / 状态测试

覆盖：

1. 自动 intent 进入 max mode。
2. 手动 max mode 时忽略自动 intent。
3. `manual` exit policy 下 command finished 不退出。
4. `onCommandFinished` exit policy 下，只退出同一个 surface 的自动 session。
5. 用户手动退出自动 session 后，同一 command 不重复进入。

## 分阶段实现

### Phase 1: 内建规则和手动退出默认值

1. 新增 `CommandToken`。
2. 新增 `CommandPresentationPolicy` 和内建规则。
3. `WorktreeTerminalState` 发 presentation intent。
4. `TerminalClient.Event` 增加 presentation intent。
5. `CanvasView` 支持自动进入，默认不自动退出。
6. 补测试。

### Phase 2: 自动退出策略

1. 增加 `AutoCanvasMaxModeSession`。
2. 支持 `onCommandFinished`。
3. 支持 `onForegroundProcessExit`。
4. 补 surface/tab cleanup 测试。

### Phase 3: 用户设置

1. `GlobalSettings` 增加 `CommandPresentationSettings`。
2. Settings UI 增加自动进入 toggle 和退出策略 picker。
3. 支持用户 override 内建规则。

## 推荐结论

优先做 Phase 1 + Phase 2 的代码结构，但默认策略选择“自动进入，手动退出”。这满足 lazygit 可读性的核心需求，也避免命令退出时突然改变用户布局。

不要把该能力塞进 `CommandIconMap`。icon 和 presentation 应该共享 token 解析，但规则表和行为分开。这样新功能对原有 icon 自动检测的影响最小，后续扩展也更清晰。
