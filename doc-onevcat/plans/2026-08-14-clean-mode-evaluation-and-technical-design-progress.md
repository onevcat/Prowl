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
| 4. Herdr 自动识别与 socket adapter | 完成，真实 session 待验证 | exact process、protocol 19、NDJSON、event、backoff/clock 与 compatibility pause 已实现；Herdr 测试连续 5 轮通过 |
| 5. 文档与最终验证 | 完成 | 用户文档、聚焦测试、完整测试、源码 build/install、format lint、静态审查和 Debug smoke 已完成 |

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
| 2026-08-15 | 保留系统 Window menu 并仅追加 Clean 主窗口入口 | 替换 `.windowArrangement` 会一并移除 Minimize、Zoom、Fill、Move & Resize 和 Bring All to Front | Clean 不提供 Prowl tab/split，但保留原生窗口管理能力 |
| 2026-08-15 | Herdr 订阅确认后重新读取 `pane.current` | initial snapshot 与 `events.subscribe` 生效之间存在焦点变化窗口，仅依赖后续 event 可能永久漏掉最新 pane | `.subscribed` 和首个 `.event` 都会重置重连退避；订阅确认时补一次 snapshot 关闭竞态 |
| 2026-08-15 | 非 fullscreen 时隐藏 `NSTitlebarContainerView` | Tahoe 会在 `.fullSizeContentView` 上方继续绘制 32 pt titlebar background/backdrop/decoration，遮住终端第一行 | Clean 获得真正 full-bleed 内容；窗口状态变化后需要重新应用隐藏配置 |

## 验证记录

- 2026-08-14：确认当前分支为 `codex/clean-mode`，分支起点为本地 `custom` (`a8a63678`)。
- 2026-08-15：静态审计 `SupacodeApp.init`：`AppLaunchProfile` 在 `makeStandardRuntime` 之前解析；Clean switch
  分支没有构造 `TmuxTerminalController`、`WorktreeTerminalManager`、`WorktreeInfoWatcherManager`、
  `PullRequestRefreshCoordinator`、`CLISocketServer` 或 `MemoryWatchdog`。
- 2026-08-15：`AppRuntimeSelector` 通过 factory 注入验证 runtime 隔离：Clean 只调用 Clean factory，Standard 只调用
  Standard factory；`SupacodeApp.init` 只消费 selector 返回的单一 runtime，不会预先构造另一条对象图。
- 2026-08-15：`AppLaunchProfileTests` 冻结现有 Standard 启动语义：未设置、显式 `worktrees`、`freestyle`、未知值与
  大小写不匹配值都保持 Standard；只有精确 `clean` 进入 Clean runtime。
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
  area 和系统 menu bar；没有 traffic-light button、sidebar、toolbar 或 tab bar。截图发现 terminal 内容虽延伸到窗口顶部，
  但第一行被顶部约 32 pt 的系统 titlebar 绘制层遮挡。
- 2026-08-15：`Cmd+,` 打开的 Settings window 保留 close/minimize/fullscreen traffic lights；General 页的
  `Default View > Launch in` 显示 `Clean Mode`。`Cmd+W` 关闭 Settings 后返回同一 shell session。
- 2026-08-15：使用另一个空的隔离 home 启动默认 Normal mode，确认 Standard runtime 仍显示
  `SidebarNavigationSplitView`、toolbar、traffic lights、Add Repository 空状态和 Worktrees menu，且启动无崩溃。
- 2026-08-15：稳定 Xcode 的 `xcrun swift-format lint --strict` 对新增 Swift 文件结果为 0；对固定基线以来全部
  Swift diff 做 changed-line 交集审计，结果同样为 0。整文件模式仍报告 70 条位于未改动基线行的旧长行；
  `git diff --check` 通过。`make format-changed` 因系统 Bash 3.2 不支持 Makefile 使用的 `mapfile` 而不能作为入口。
- 2026-08-15：Window menu 改为在 `.windowArrangement` 后追加 `Prowl`，UI 复查确认 Minimize、Zoom、Fill、
  Move & Resize、Bring All to Front 和 Prowl 均存在。
- 2026-08-15：Herdr event stream 在 `subscription_started` 后发送 `.subscribed`；adapter 收到后重新读取
  `pane.current`，同时让 `.event` 重置 reconnect backoff，以兼容 `.bufferingNewest(1)` 覆盖订阅状态的情况。
- 2026-08-15：LLDB live view hierarchy 确认遮挡层为 `NSThemeFrame` 下 frame 为 `(0, 1052, 1728, 32)` 的
  `NSTitlebarContainerView`，其子树包含 `NSTitlebarBackgroundView`、`CABackdropLayer` 和
  `_NSTitlebarDecorationView`；不是透明的 `CleanWindowConfigurationView`。非 fullscreen 时隐藏该容器，并在
  next main-actor turn、窗口成为 key/main、恢复最小化和退出 fullscreen 后重新应用。live 复验
  `NSTitlebarContainerView.isHidden == true`；窗口测试同时断言 content view 从 `minY == 0` 延伸到
  `maxY == window.frame.height`，确保隐藏 chrome 后没有遗留顶部布局占位。
- 2026-08-15：`HerdrInputContextTests` 在关闭 parallel testing 后连续执行 5 轮，全部通过；覆盖 protocol
  compatibility、initial snapshot、subscription race、event refresh、retry/backoff、stop 后丢弃 stale result 等路径。
- 2026-08-15：Clean 聚焦集合 `AppLaunchProfileTests`、`CleanAppFeatureTests`、
  `CleanWindowAndSurfaceTests`、`HerdrInputContextTests`、`TerminalInputSourceCoordinatorTests` 共
  `34 tests / 5 suites`，结果为 `0 failures`、`TEST SUCCEEDED`。
- 2026-08-15：完整回归与固定 `custom@a8a63678` 基线均运行到结束。当前为 `passed: 1788`、`failed: 42`、
  `total: 1830`，基线为 `passed: 1758`、`failed: 42`、`total: 1800`；两侧 42 个失败 test identifier 集合完全一致，
  当前没有仅由 Clean 改动引入的失败。失败均属于固定基线已有的状态断言或测试依赖问题，包括 Freestyle action
  target、Canvas/Repositories/Command Palette 状态、`ContinuousClock.now` test dependency、worktree path、shortcut
  display、detached-card ID 与 Canvas geometry。唯一 warning 是 test target deployment target `26.1` 高于当前 SDK
  支持上限 `26.0.99`。
- 2026-08-15：最终执行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make install-dev-build`，
  结果为 `errors: 0`、`warnings: 0`、`failed_tests: 0`、`linker_errors: 0`，并安装到
  `/Applications/Prowl.app`。
- 2026-08-15：最终隔离 home 复验确认 `defaultViewMode=clean`，运行期间没有创建 tmux、CLI socket、repository 或
  layout persistence 文件。由于已有同 bundle 用户实例必须保留，并行启动的第二实例未产生可观察的 shell 子进程；
  smoke 结束后仅终止隔离 PID，确认原用户实例继续运行。

## 未决风险

- full-size titlebar 区域的 window drag 与 Ghostty mouse input 可能冲突，需以 terminal 输入完整性优先进行实机验证。
- strict Herdr protocol `19` 会在 Herdr wire protocol 升级后暂停输入法集成；升级需要显式 contract review。
- 完整测试当前与固定 `custom` 基线均有同一组 42 项失败；本功能以差分回归和已通过的 Clean/Herdr 聚焦集合隔离
  验证，基线测试修复不纳入 Clean 改动范围。
- 当前 agent 不在 Herdr-managed pane（`HERDR_ENV` 未设置），按 Herdr 操作约束不能 attach 或控制真实 session；
  socket contract 已与本机 Herdr protocol `19` 源码核对，但 pane focus 驱动的真实输入法切换仍是运行时验证项。
- full-size titlebar 区域没有额外 drag strip，以避免吞掉 terminal 首行鼠标事件；窗口拖动手感和 native fullscreen
  的人工验证仍需在日常使用中观察。
- 隐藏 `NSTitlebarContainerView` 后 Computer Use 无法取得该窗口的 CGWindow 截图；当前视觉结论由 live view
  hierarchy 与 `isHidden == true` 证明，最终像素级截图仍需人工观察补充。
- 最终 build/install 后的并行同 bundle smoke 无法替代正常单实例启动验证；普通 shell 已由较早的隔离单实例 smoke
  证明，本次新增的 runtime selector、Standard profile 冻结与窗口几何分别由聚焦测试覆盖。
