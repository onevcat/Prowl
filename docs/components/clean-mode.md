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
- 不显示 sidebar、toolbar、tab bar、title、empty state 或 traffic lights。
- terminal 延伸到原 titlebar 和 traffic-light 区域；进入 native fullscreen 后也不会恢复 titlebar chrome。

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

在 shell 中手动输入 `herdr` 即可进入 Herdr。Prowl 精确识别前台 `herdr` process 后，才连接 default session 的
只读 Unix socket：

```text
$XDG_CONFIG_HOME/herdr/herdr.sock
或 ~/.config/herdr/herdr.sock
```

Prowl 不发送控制命令。它只读取 focused pane，并订阅 pane lifecycle event：

- focused pane 存在 agent 时，按该 `pane_id` 恢复已记忆的输入法。
- 首次进入尚未记忆输入法的 agent pane 时，使用最近一次从 command/shell pane 切换前记录的非 ABC 输入法；如果没有 fallback，则保持当前输入法。
- focused pane 是 shell/command 时，选择 ABC。
- 不同 Herdr pane 分别记忆输入法。
- `Option+H/J/K/L` 不作为 Prowl Canvas 导航处理，按键会继续传给 terminal，供 Herdr 自己切换 tab/workspace。
- Clean runtime 强制启用 `macos-option-as-alt = true`，确保 Option 组合编码为 terminal Alt；代价是 Clean 中不能用
  Option 组合输入 macOS 特殊字符。
- 退出或 detach Herdr 后，自动恢复外层 terminal 的前台进程判断。

Herdr JSON API 的每条 Unix socket connection 只处理一条 request。Prowl 使用独立短连接完成 protocol check 和
`pane.current` 查询，并为 `events.subscribe` 保留一条单独的长连接；这些请求不能复用同一条 connection。

socket 不存在、断开、响应异常或 protocol 不兼容时，Prowl 保持当前输入法并静默重试或停止集成，不显示产品
overlay。首期只支持 bare `herdr` 的 default local session，不支持 named session、remote Herdr 或自定义
`HERDR_SOCKET_PATH`。

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
