# Clean Mode

> Clean Mode 是 Prowl 的独立启动 runtime：一个占满主窗口的普通 shell，不加载 repository/worktree 产品界面。

**Keywords:** clean mode, standalone shell, Herdr, traffic lights, input source, tmux, launch mode

**Related:** [view-modes](view-modes.md) · [settings](settings.md) · [terminal](terminal.md)

## 进入与退出

1. 打开 **Settings → General → Default View**。
2. 在 **Launch in** 中选择 **Clean Mode**。
3. 退出并重新打开 Prowl。

这个设置只决定下一次启动，不会在当前进程中热切换 runtime。在 Clean 中可以用相同 Picker 选择
Normal、Shelf 或 Canvas，下一次启动时回到 Standard runtime。

## 启动内容

Clean 只创建一个 Ghostty terminal surface：

- 初始目录是用户 home directory。
- 启动普通交互式 shell，不注入命令。
- 不自动启动、attach 或控制 Herdr。
- Herdr 未激活时不显示 sidebar、toolbar、tab bar、title、empty state 或 traffic lights；进入 Herdr 并完成状态同步后，
  在 terminal 左侧显示 native Herdr sidebar。
- 在 Clean native Herdr chrome 中按 `⌘S` 可切换 sidebar 显示；tab bar 和 terminal 内容保持不变。
- terminal 延伸到原 titlebar 和 traffic-light 区域；主窗口保留可接收键盘焦点的 native window style，同时隐藏
  titlebar chrome，并把不可见 titlebar 区域中的鼠标事件转发给 terminal；进入 native fullscreen 后也不会恢复
  titlebar chrome。

窗口仍保留 edge resize、native fullscreen、Mission Control、frame restore、`⌘W`、系统 Window menu 和 Dock
reopen。由于整个顶部区域都交给 terminal mouse input，Clean 不额外放置会吞掉首行点击或选择的 drag strip。

四周留白由 Ghostty 配置控制，不是 Prowl view padding。以下配置会移除四周 padding：

```ini
window-padding-x = 0
window-padding-y = 0
window-padding-balance = false
```

也可以分别设置两侧，例如 `window-padding-x = 8,12` 表示左侧 8pt、右侧 12pt；`window-padding-y` 的两个值
依次表示顶部和底部。配置变更只作用于新创建的 terminal surface，需要重启 Clean 主窗口后生效。

## Herdr

在 shell 中手动输入 `herdr` 即可进入 Herdr。Prowl 精确识别前台 `herdr` process 后，会先等待当前 Clean terminal surface 专属的 client-local native chrome contract。支持该 contract 的 Herdr client 是 machine catalog、Local/SSH endpoint、terminal presentation、focus 和 input 的唯一 authority；Prowl 只显示其聚合 projection 并转发 endpoint-qualified intent，不直接连接远端 Herdr server。

contract 在 surface 创建时通过一次性 Unix socket、client instance ID、surface proof 和 peer PID 绑定；首个合法 claim 会关闭 listener，后续进程不能接管同一 surface。Local projection ready 后即可显示首屏，不等待 saved SSH machine 完成连接。250ms 内没有 client claim 时，本次 surface 生命周期固定使用兼容模式，通过 default session 的只读 Unix socket连接 Local。client 已 claim 但 1 秒内没有提交完整 `aggregate_sync_commit` 时，本次 surface 固定进入 incompatible，不回退兼容模式：

```text
$XDG_CONFIG_HOME/herdr/herdr.sock
或 ~/.config/herdr/herdr.sock
```

aggregate mode 下，sidebar 和 tab bar 使用 Herdr client 提交的状态：

- Local 和所有 saved SSH machine 按 Herdr catalog 顺序分组显示；每台 machine 独立展示 connecting、reconnecting、Attention、disabled 和 stale 状态。
- Spaces 和 Agents 都保留 machine 来源。点击 online remote workspace 或 Agent 会请求 Herdr client执行完整 endpoint activation；pending 状态不会提前改变 tab bar、terminal、process decoration 或输入法 target。
- tab bar 只显示 Herdr 已提交的 active endpoint。activation、rollback 或 contract 断连期间无法证明 presentation owner 时，native chrome 显式显示 unavailable，不会回退或混用 Local authority。
- workspace、tab、Agent pane 和普通 shell pane 都会按各 endpoint 的 Herdr server 层级显示。
- spaces row 的第二行显示 workspace branch；branch 信息在后台缓存解析，不阻塞 sidebar 渲染。
- spaces 右上角的 ellipsis 是可点击的 native menu button，菜单提供 new 和 menu 项。
- 普通 pane 使用 `agent == nil` 判定，不把 shell 当作 Agent；Agent pane 显示 agent 名称和状态。
- Agent title 和包含 Agent pane 的 tab title 左侧都会显示对应 provider 的 full-color canonical 图标；未知 provider 使用
  Zap 图标兜底。前台进程是 `ssh` 或 `mosh-client` 的普通 tab 在同一图标位显示 SSH badge（`HerdrProcessSshIcon`：
  14pt 槽位内等比放大填充 24 网格、idle 状态同款绿色、无背景 template）；badge 替代进程名文字，tab 只显示
  badge + directory segment；agent 图标优先于 SSH badge，两者同时存在时只显示 agent 图标。
- Agent title 第一行显示 `foreground_cwd`/`cwd` 的目录名，并与 workspace/tab label 去重；第二行保留 agent 名称。
- Herdr tab 的 `label` 是当前实际名称，`custom_name` 是手动命名标记。自动状态下 `label` 跟随 focused pane 的 cwd basename；
  手动状态下 cwd 变化不会覆盖 `label`，即使手动名称恰好等于当前目录名也保持手动状态。
- Goto、Navigator、mobile switcher、window title、terminal attach、`session.snapshot`、`tab.list`/`tab.get` 和 Clean native tab bar
  都读取 Herdr 的同一个 `label`，不再使用 `1`、`2` 等 tab 序号作为名称。
- 当前 pane 和刚离开的 pane 有明确 foreground application 时，tab title 显示 `process · directory`；shell、`starship` 和
  transient helper 不参与识别。进程退出后只恢复 directory segment，不改变 Herdr 的手动命名状态。SSH badge 复用同一
  foreground process 判定：连接期间替代进程名文字显示，进程退出后 badge 消失并恢复普通 directory-only 展示。
- linked worktree、process title 和 Agent icon 都是 Prowl 的独立视觉装饰。linked worktree 只在自动状态下为 directory segment
  增加 rich presentation，手动 directory segment 始终优先；只有 Herdr snapshot 已提供 worktree provenance 时才显示 linked-worktree
  装饰，没有 provenance 时直接使用 server `label`，不在 tab projection 内启动 Git 子进程；Herdr 的 `label`/`custom_name` 不通过装饰字符串反推。
- tabbar 右键菜单中的 **Rename Directory Name...** 只修改 directory segment，进程名和 Agent icon 保持独立显示；已有手动名称时会同时提供
  **Use Automatic Directory Name**，Rename sheet 中也提供 **Use Automatic Name**。清除操作发送 `tab.rename` 的 `label: null`，
  由 Herdr 将 `custom_name` 清空并恢复当前 cwd。
- tab name 逻辑不增加 cwd polling、额外子进程、每次 render 的 Git/文件系统访问或 socket 写入循环；自动名称只在已有 cwd/focus
  事件中更新，Prowl 的装饰变化不触发 Herdr rename。
- tabbar 右侧的 `+` 会直接创建未命名 tab，不弹出命名输入框；重命名和恢复自动名称都通过 tab context menu 或 Rename sheet 操作。
- agents header 的 `grouped`/`priority` 控件对应 Herdr 自带的 workspace 顺序和 attention 优先级排序。
- 点击 workspace、tab 或 pane row 会向当前 Herdr client发送带 endpoint connection generation、server boot ID 和 snapshot revision 的 focus/activate intent。相同 endpoint 内的 selection 由后续 projection 确认；跨 endpoint selection 只有 presentation fence 完成后才成为 committed selection。
- pane 退出事件会立即从 native chrome 的本地投影中移除对应 pane；若该 pane 是 tab/workspace 的最后一个 pane，也会同步移除空 tab/workspace。随后到达的旧 snapshot 不会恢复已关闭的 tab。
- Herdr protocol 21-24 的 workspace、worktree、tab、pane 创建、关闭、移动、重命名、聚焦、metadata 和 layout 更新都会触发一次完整 snapshot 刷新；rename/focus burst 使用 100ms debounce，结构变更沿用 immediate refresh。protocol 24 的 tab snapshot 可独立携带 linked worktree provenance，因此普通 workspace 中位于 linked checkout 的 tab 也能保留仓库身份。
- client-local contract 断开、sequence gap 或 payload 不兼容时，aggregate native chrome 显式进入 unavailable/incompatible 状态并停止 remote action；不会在同一 surface 生命周期降级到 Local legacy socket。仅启动 claim 确认不存在时才进入兼容模式。
- Sidebar 不接管 Herdr terminal stream，不实现 binary client protocol，也不持久化 Herdr machine、workspace、tab 或 pane。

aggregate mode 的输入法与 process decoration 都以 `EndpointKey + pane ID` 为 identity，并只跟随 committed active endpoint。process info请求由 Prowl 发给当前 Herdr client，再由 Herdr 通过对应 endpoint command lane 执行；结果必须匹配 connection generation、server boot ID 和 snapshot revision 后才进入 cache。兼容模式沿用 default Local socket adapter：

- focused pane 存在 agent 时，按该 `pane_id` 恢复已记忆的输入法。
- 首次进入尚未记忆输入法的 agent pane 时，使用最近一次从 command/shell pane 切换前记录的非 ABC 输入法；如果没有 fallback，则保持当前输入法。
- focused pane 是 shell/command 时，选择 ABC。
- 不同 Herdr pane 分别记忆输入法。
- Herdr 的 workspace/tab/pane focus 事件会立即刷新 focused pane；事件与 polling 同时触发时只保留一个进行中的查询。
- Clean 主窗口从隐藏或非 active 状态恢复时，立即重放已缓存的 focused pane 输入法上下文；通过 Hammerspoon、
  launcher 或 Dock 返回同一 Herdr pane 不需要等待下一次 socket 查询或 polling。
- 检测到不兼容的 Herdr protocol 时，Clean 会在窗口中弹出错误提示，并暂停输入法同步；离开 Herdr 后重新进入会再次检测。
- 如果 focus event 丢失或 Herdr 版本没有提供该事件，则通过 `pane.current` 每 100ms 轮询更新 focused pane。
- `Option+H/J/K/L` 不作为 Prowl Canvas 导航处理，按键会继续传给 terminal，供 Herdr 自己切换 tab/workspace；native Herdr chrome client 的 client-local navigation 会由 Herdr 转发为既有的 workspace/tab/pane focus event，Prowl 通过事件流更新 sidebar 和 tab bar，不在本地推断导航顺序或额外拉取 snapshot。
- Clean runtime 强制启用 `macos-option-as-alt = true`，确保 Option 组合编码为 terminal Alt；代价是 Clean 中不能用
  Option 组合输入 macOS 特殊字符。
- 退出或 detach Herdr 后，自动恢复外层 terminal 的前台进程判断。

Prowl 兼容模式支持 Herdr JSON API protocol 21-24；protocol 19、20 及未来 protocol 25 在 protocol check 前拒绝并隐藏 legacy native chrome。Herdr protocol 23、24 只变更二进制 client/server wire，兼容模式使用的 JSON snapshot contract 保持不变。Herdr JSON API 的每条 Unix socket connection 只处理一条 request。Prowl
在 adapter 启动或重连时使用独立短连接完成 protocol check，随后为 legacy terminal chrome 按三步建立生命周期：先用短连接取得 discovery
`session.snapshot` 以获得当前 pane IDs，再用单一 multiplexed `events.subscribe` 长连接订阅 global 与这些 pane-specific events 并等待 ack，最后重新取得 authoritative
`session.snapshot` 作为首个对外状态；两次 snapshot 之间到达的事件由同一 stream/consumer 保留。authoritative snapshot 发现 pane-set 变化时，取消旧订阅并重建整轮生命周期。

compatibility socket 不存在、断开、响应异常或 protocol 不兼容时，Prowl 保持当前输入法并静默重试或停止 legacy 集成，不显示产品 overlay。compatibility mode 只支持 bare `herdr` 的 default local session；named session 和 saved SSH machine 需要 client-local native chrome contract。

## 与 Standard runtime 的边界

Clean 不构造或运行以下 Prowl module：

- Repository/worktree loader、watcher、GitHub/PR coordinator。
- Prowl terminal tab、split、Canvas、Shelf、Freestyle、Command Palette 和 Active Agents panel。
- `TmuxTerminalController`、anonymous tmux restore、detached-card recovery 和 terminal layout persistence。
- Prowl CLI socket server；`prowl` CLI 不能寻址 Clean surface。

`useAnonymousTmuxBackedTerminals` 与 `restoreTerminalLayoutOnLaunch` 在 Clean 中不会生效，也不会被 Clean 启动过程
改写。用户仍可像普通 shell 一样手动运行自己的 `tmux`；互斥范围只针对 Prowl-managed tmux。

## Settings 与系统菜单

Clean 保留 Settings、Updates、Quit、Close Window、Window 和 Help 等 app-level 能力。Settings window 使用标准
macOS chrome 和 traffic lights；隐藏规则只作用于 Clean 主窗口。
