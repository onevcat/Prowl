# Prowl Clean Mode 实施进度

关联设计：[Prowl Clean Mode 可行性评估与技术方案](2026-08-14-clean-mode-evaluation-and-technical-design.md)

## 当前状态

- 状态：已完成
- 实现基线：本地 `custom` (`a8a63678`)
- 目标分支：`codex/clean-mode`
- 远端同步：禁止；实施期间不执行 `fetch`、`pull`、`rebase` 或 merge `main`
- 开始日期：2026-08-14

## 阶段进度

| 阶段 | 状态 | 验证 |
|---|---|---|
| 0. 固定基线与实施记录 | 完成 | 已从本地 `custom` 创建 `codex/clean-mode`，未同步远端 |
| 1. 启动设置与 runtime 分流 | 完成 | profile 在 Standard-only 对象构造前解析；Clean 不创建 repository/tmux/CLI 对象图 |
| 2. full-bleed 单 surface Clean terminal | 完成 | surface 延迟到 app launch 后创建；Debug app 已完成 shell、窗口与 Settings smoke |
| 3. 输入法 target/router | 完成 | Standard surface 与 Herdr pane 使用 typed target；已有独立记忆回归测试 |
| 4. Herdr 自动识别与 socket adapter | 完成，真实 session 待验证 | exact process、protocol 19、NDJSON、event、backoff/clock 与 compatibility pause 已实现 |
| 5. 文档与最终验证 | 完成 | 用户文档、最终源码 build/install、format lint、静态审查和 Debug smoke 已完成 |

## 已确认约束

- Clean 是独立 runtime profile，不是 Freestyle 或 repository presentation。
- Settings 只在现有 `Default View > Launch in` Picker 增加 `Clean Mode`。
- Clean 只启动一个 home-directory 普通 shell，不自动启动或 attach Herdr。
- Clean 不构造 Prowl-managed tmux、tab、split、repository、CLI 或 layout persistence 依赖。
- Herdr 由 foreground process 自动识别；只有进入 Herdr 后才启用只读 socket adapter。
- Clean main window 不显示 sidebar、toolbar、tab bar、titlebar、title 或 traffic lights。
- 保留 native resize、fullscreen、Window menu 和 frame restore，不使用 borderless window。

## 取舍记录

| 日期 | 决定 | 原因 | 影响 |
|---|---|---|---|
| 2026-08-14 | 从当前本地 `custom` 创建实现分支 | 自动输入法功能只存在于 `custom`，公共祖先不包含目标依赖 | 避免重复移植；Clean 首期集成回 `custom` |
| 2026-08-14 | 不同步 `main` 或 upstream | 当前分支冲突较多，用户要求固定本地基线 | 实现不吸收更新后的上游变化，后续同步单独处理 |
| 2026-08-14 | `Startup Profile` 仅作为内部类型 | 用户界面已有 `Launch in`，增加第二个设置会造成语义重复 | UI 只新增一个 `Clean Mode` Picker item |
| 2026-08-15 | Clean 启动不发送 `SettingsFeature.task` | 该 action 会探测 tmux，并可能在 tmux 不可用时改写全局 anonymous-tmux 设置 | 使用启动时已读取的 Settings state 直接配置 Updates；Clean 不触碰 tmux setting |
| 2026-08-15 | 消费 Ghostty tab/split/palette action | callback 留空会把 action 标记为未处理，可能继续落到 app command；Clean 需要结构性禁用这些能力 | 不创建 tab/split，只返回 handled；`close_tab` 映射为关闭主窗口 |
| 2026-08-15 | Herdr protocol 严格支持版本 `19` | 跨仓库 wire schema 需要在不兼容时停止，而不是按未知结构猜测 input context | Herdr protocol 升级后需显式审核并更新常量；不匹配时保持当前输入法且无可见 overlay |
| 2026-08-15 | Unix socket 设置 `SO_NOSIGPIPE` 和 2 秒 request timeout | server 断开期间写 socket 不应触发进程级 `SIGPIPE`，request 不应永久阻塞 | event stream handshake 有超时，订阅建立后恢复无限读；断线按上限 2 秒退避重连 |
| 2026-08-15 | 不兼容响应进入 compatibility pause | Clean 的周期性 foreground probe 不应在 protocol 不兼容时每秒重新启动 adapter | 同一次 Herdr 前台周期保持暂停；检测到真正退出 Herdr 后才允许下次进入重新握手 |
| 2026-08-15 | Ghostty surface 延迟到 `CleanRootView.onAppear` 创建 | `SupacodeApp.init` 早于 `applicationDidFinishLaunching`，此时创建 surface 会返回 `nil` | host 初始化仍不构造 Standard runtime；首帧使用稳定透明容器，app launch 完成后创建唯一 shell surface |
| 2026-08-15 | shell 退出时丢弃 surface，手动关窗时保留 surface | Ghostty 的 close callback 通过 `processAlive` 区分进程退出和用户关窗；保留已退出的 surface 会导致 reopen 得到 dead terminal | `exit` 后下次 reopen 创建新 shell；`Cmd+W` 关窗后 reopen 仍返回原 session |

## 验证记录

- 2026-08-14：确认当前分支为 `codex/clean-mode`，分支起点为本地 `custom` (`a8a63678`)。
- 2026-08-14：基线 `make test` 在测试执行前失败，`failed_tests: 0`。错误来自缓存中的
  `swift-composable-architecture/NavigationStack+Observation.swift:166`：无法对 main-actor isolated subscript
  形成 key path；另有 9 个第三方依赖扫描/link deployment warnings。该结果发生在 production code 修改前，作为
  基线工具链/依赖编译问题跟踪，后续仍需通过聚焦测试、`make check` 和 `make install-dev-build` 验证本功能。
- 2026-08-14：使用稳定版 Xcode 运行聚焦测试时，test target 仍会编译全部测试源，并被 `custom` 基线中
  `CanvasView` 测试引用的三个缺失测试接口阻断：`isFreestyleNewTerminalChordKey`、`FocusRequest` 和
  `nextHandledCanvasFocusRequestToken`。该问题发生在 Clean production code 编译前，保留为基线测试障碍。
- 2026-08-15：稳定版 Xcode app-only build 进入新增 production 源码编译，确认并定位 default
  `MainActor` isolation 与 Herdr blocking socket 层冲突；wire/socket pure type 已按仓库既有模式显式标注
  `nonisolated`。随后沙箱外复验命令的自动审批通道异常中断，命令未执行；未通过改 cache/HOME 绕过，待正式
  `make install-dev-build` 一并复验。
- 2026-08-15：静态审计 `SupacodeApp.init`：`AppLaunchProfile` 在 `makeStandardRuntime` 之前解析；Clean switch
  分支没有构造 `TmuxTerminalController`、`WorktreeTerminalManager`、`WorktreeInfoWatcherManager`、
  `PullRequestRefreshCoordinator`、`CLISocketServer` 或 `MemoryWatchdog`。
- 2026-08-15：对照本机 Herdr `events.rs`、`response.rs`、`panes.rs` 与 Socket API 文档，确认
  `pane.current` / `pane_current`、`events.subscribe` / `subscription_started`、默认 socket path 和 protocol `19`
  wire contract；decoder 仅依赖 `pane_id`、`agent`、`agent_status` 和必要 envelope 字段并忽略未知字段。
- 2026-08-15：更新 `docs/components/view-modes.md`、`docs/components/settings.md`、
  `docs/reference/settings-fields.md`、文档索引，并新增 `docs/components/clean-mode.md`。
- 2026-08-15：在最终 Herdr transient-probe 保护和 shell-exit lifecycle 修复完成后，重新执行
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make install-dev-build`：`errors: 0`、`warnings: 0`、
  `failed_tests: 0`、`linker_errors: 0`，并安装到 `/Applications/Prowl.app`。
- 2026-08-15：使用隔离的 `CFFIXED_USER_HOME` 和 `defaultViewMode=clean` 启动 production 签名 Debug app。
  进程树确认创建 `/usr/bin/login` 与交互式 `zsh` 子进程；terminal 执行
  `printf 'CLEAN_SMOKE:%s\\n' "$PWD"`，输出 `CLEAN_SMOKE:/tmp/prowl-clean-smoke-home`。
- 2026-08-15：Computer Use 检查 Clean main window：AX 树只有无标题 `main` window、单一 terminal scroll/text
  area 和系统 menu bar；没有 traffic-light button、sidebar、toolbar 或 tab bar。截图确认 terminal 内容延伸到窗口顶部。
- 2026-08-15：`Cmd+,` 打开的 Settings window 保留 close/minimize/fullscreen traffic lights；General 页的
  `Default View > Launch in` 显示 `Clean Mode`。`Cmd+W` 关闭 Settings 后返回同一 shell session。
- 2026-08-15：使用另一个空的隔离 home 启动默认 Normal mode，确认 Standard runtime 仍显示
  `SidebarNavigationSplitView`、toolbar、traffic lights、Add Repository 空状态和 Worktrees menu，且启动无崩溃。
- 2026-08-15：显式 changed-file `swift-format` 和 `xcrun swift-format lint --strict` 已执行，最终修改后再次验证通过，
  `git diff --check` 通过。完整递归 lint 被 `custom` 基线中未触及的 Canvas/tmux 等格式问题阻断；
  `make format-changed` 因系统 Bash 3.2 不支持 Makefile 使用的 `mapfile` 而不能作为入口。
- 2026-08-15：SwiftLint 在沙箱内外均因 `sourcekitdInProc.framework` 加载失败而无法运行；稳定版
  `DEVELOPER_DIR` 未解决。聚焦 `xcodebuild test` 未执行成功，且当前 `custom` test target 已知会被三个既有
  Canvas 测试接口缺失阻断：`isFreestyleNewTerminalChordKey`、`CanvasView.FocusRequest`、
  `nextHandledCanvasFocusRequestToken`。
- 2026-08-15：最终源码 build/install 后再次请求运行四组 Clean 聚焦测试，沙箱外命令在启动前因自动审批 stream
  断开被拒绝，因此没有产生新的 test result；未通过修改 cache、`HOME` 或替代命令绕过。production target 的
  fresh build/install 结果仍为 0 error、0 warning。

## 未决风险

- full-size titlebar 区域的 window drag 与 Ghostty mouse input 可能冲突，需以 terminal 输入完整性优先进行实机验证。
- strict Herdr protocol `19` 会在 Herdr wire protocol 升级后暂停输入法集成；升级需要显式 contract review。
- 当前 `custom` test target 的既有 Canvas 测试编译错误会阻断所有聚焦测试执行，需区分 Clean 源码编译结果与
  test-target 基线问题。
- 当前 agent 不在 Herdr-managed pane（`HERDR_ENV` 未设置），按 Herdr 操作约束不能 attach 或控制真实 session；
  socket contract 已与本机 Herdr protocol `19` 源码核对，但 pane focus 驱动的真实输入法切换仍是运行时验证项。
- full-size titlebar 区域没有额外 drag strip，以避免吞掉 terminal 首行鼠标事件；窗口拖动手感和 native fullscreen
  的人工验证仍需在日常使用中观察。
