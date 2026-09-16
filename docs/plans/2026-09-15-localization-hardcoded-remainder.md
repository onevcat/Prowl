# 汉化剩余硬编码清单

日期：2026-09-15  
分支：`feat/app-language-settings`  
对照：`Localizable.xcstrings` 已提取 891 keys、883 条 `zh-Hans`；`InfoPlist.xcstrings` 权限说明已译。

本清单只记 **编译器抽不进 catalog**、中文包盖不住的用户可见文案。  
`Text("…")` / `Button("…")` / `Label("…")` / `Section("…")` / `.help("字面量")` / `.navigationTitle("…")` 已进 catalog，不重复列出。

子 agent 扫描因额度失败，本文件由主会话直接 grep + 读源码汇总。

---

## 结论

已译 catalog 只覆盖 SwiftUI `LocalizedStringKey` 字面量。下面这些路径把 **普通 `String`** 交给 UI，启动语言为中文时仍显示英文：

| 种类 | 约计 | 优先级 | 做法 |
|---|---:|---|---|
| `TextState("…")` 警告框 | 50 | P0 | 改为 `TextState(String(localized:))` 或 `LocalizedStringResource` |
| `showToast(.…("…"))` | 29 | P0 | 显示边界 `String(localized:)` |
| AppShortcuts `title:` | ~75 | P0 | 显示用 localized，**不改 CommandID** |
| 命令面板 `CommandPaletteItem(title:)` | ~20 | P0 | 构造时 localized；保留英文 keywords |
| 设置枚举 `title`/`label` | ~40 | P0 | `String(localized:)` 返回值 |
| AppKit 菜单 / Alert / 文件面板 | ~20 | P0 | `String(localized:)` |
| `WindowTitle` 常量 | 3 | P1 | `String(localized:)`（DEBUG 探针除外） |
| `helpText(title: String)` | ~30 | P1 | 入参改 `LocalizedStringResource` 或内部 localized |
| Ask Agent Help chrome | 结构已分 | P1 | chrome 跟应用语言；prompt 跟系统首选（计划合同） |
| 用户数据 / CLI / Ghostty action ID | — | 跳过 | 见文末 |

G1a DEBUG 探针（设置页、窗口标题、右键菜单、Clone 面板）仍在，收尾时应删。

---

## P0 — AppKit

### 终端右键菜单

`supacode/Infrastructure/Ghostty/GhosttySurfaceView+Keyboard.swift`

| 行 | 字符串 | 建议 |
|---|---|---|
| 284 | `Copy` | localize |
| 286 | `Paste` | localize |
| 290 | `Split Right` | localize |
| 296 | `Split Left` | localize |
| 302 | `Split Down` | localize |
| 308 | `Split Up` | localize |
| 315 | `Reset Terminal` | localize |
| ~312+ | `Change Title...` | localize |
| 273–281 | `G1a AppKit menu probe` | DEBUG，删 |

`menuItem(title:action:symbol:)` 收的是 `String`，调用处改 `String(localized:)` 即可。

### NSAlert

| 文件 | 行 | 字符串 | 建议 |
|---|---|---|---|
| `Clients/Updates/UpdaterClient.swift` | 202–205 | `Install Update and Relaunch?` / `Prowl will quit and relaunch…` / `Install and Relaunch` / `Later` | localize（计划点名） |
| `Features/Terminal/Models/WorktreeTerminalState+Surfaces.swift` | 60–65 | `target.messageText`、`closeConfirmationMessage`、`Cancel` | 关闭确认文案 + Cancel localize |
| 同上 | 572–582 | `Change Tab Title` / `Leave blank to restore the default.` / `OK` / `Cancel` | localize |

### NSOpenPanel

| 文件 | 行 | 字符串 | 建议 |
|---|---|---|---|
| `CloneRepositoryView.swift` | 100 | G1a probe | DEBUG，删 |
| `WorkspaceCreationPromptView.swift` | 466, 506 | `Choose` | localize |
| 同上 | 510–511 | `Choose a bare repository folder` / `Choose a repository folder` | localize |
| `RepositoryAppearancePickerView.swift` | 437–438 | `Choose` / `Choose an image to use as this repository's icon.` | localize |

`WorkflowHistoryFeature` 的 `NSSavePanel` 只有默认文件名，无用户可见提示，跳过。

---

## P0 — TCA `TextState("…")`（约 50 处）

TCA `TextState(String)` **不会**进 String Catalog。计划点名的退出确认、Run Script、安装更新都在这类路径上。

### 退出确认（计划必验）

`Features/App/Reducer/AppFeature.swift`

- 735 `Quit Prowl?`
- 738 `Quit`
- 741 `Cancel`
- 744 `This will close all terminal sessions.`
- 719 `OK`（打开失败类 alert）

### Settings 警告

`Features/Settings/Reducer/SettingsFeature.swift`

- 555–567 CLI 安装/卸载成功文案（含 `\(path)`）
- 578–580 CLI Error / OK
- 607–616 系统通知权限：`Prowl cannot send system notifications` / `Open System Settings` / `Cancel` + 长说明

`AgentProfileEditorFeature.swift`：`Allow Unrestricted Execution?`、`Remove “\(profile.name)”?`、`Remove Profile`、`Remove and Trash Files`

`AgentSkillsFeature.swift`：`Agent Skills Error`

`WorkflowSettingsDetailFeature.swift`：`Cannot Review Bundle`、`Delete Workflow?`、`Move to Trash`、插值 Trash 说明、`Could Not Delete Workflow`

`WorkflowsSettingsFeature.swift`：`Workflows Error`

### 仓库 / 工作树

`RepositoriesFeature+RepositoryLoading.swift`：`Remove repository?` / `Remove repository` / `Cancel` / `OK`

`RepositoriesFeature+RepositoryManagement.swift`：`Some worktrees couldn't be removed` / `Delete Folder Anyway` / `Keep Folder`

`RepositoriesFeature+WorktreeLifecycle.swift`：`Archive worktree?`、`Archive (⌘↩)`、`Archive \(count) worktrees?`、`Force delete branch?`、`Force Delete`、`Keep Branch`

GitHub 集成还有一批 PR merge/close/CI 的 `TextState`（`RepositoriesFeature+GithubIntegration.swift`），同样要 localize。

**改法：** 静态句用 `TextState(String(localized: "…"))`；插值用 `String(localized: "… \(name)")` 或 `String.LocalizationValue`。快捷键 `⌘↩` 保留。

---

## P0 — Toast（约 29 处）

`showToast(.success/.warning/.inProgress("…"))` 是普通 String。

代表（非穷尽，grep 已列全路径）：

- `AppFeature.swift`：`prowl installed at \(path)`、`CLI install failed:`、`Workflow created at \(path)`、skill link 成功/失败、`Saved terminal layout cleared`、`\(notice.workflowName) completed`
- `AppFeature+AgentProfiles.swift` / `+TerminalEvents.swift`：`Couldn't launch “\(profile.name)”`
- `AppFeature+Handoff.swift`：`No agent detected in the current pane`
- `AppFeature+WorkflowStart.swift`：`The selected worktree is no longer available.`
- `RepositoriesFeature+GithubIntegration.swift`：`Merging pull request…`、`Pull request merged`、`CI failure logs copied` 等
- `RepositoriesFeature+WorkspaceCreation.swift`：`Workspace created` / `Workspace creation canceled`

动态 `error.message` / `notice.title`：若来自 CLI/系统，**不要**按英文匹配翻译；只有 Prowl 自有模板才 localize。

---

## P0 — 命令面板

`CommandPaletteItem.title` 是 `String`。

`Features/CommandPalette/Reducer/CommandPaletteFeature.swift` 硬编码标题包括：

`Change Tab Icon...`、`Repo Settings`、`Check for Updates`、`Open Settings`、`Open Repository`、`New Workspace`、`New Worktree`、`Refresh Worktrees`、`Jump to Latest Unread`、`Install Command Line Tool`、`Stop Script`、`Run Script`、`Rename Branch`、`Delete Worktree`

`CommandPaletteOverlayView.swift`：`Recent`、`Suggested`（若以 `String` 传入 header）

自定义命令用 `command.resolvedTitle`（用户数据）→ **跳过**。  
Ghostty 行用 `command.title` 作 **命令身份**（`ghosttyCommand(action|title)`）→ **显示可译，ID 禁止改**。

keywords 保留英文，并按计划加中文关键词。

---

## P0 — AppShortcuts 显示名（~75）

`supacode/App/AppShortcuts.swift` 每个命令的 `title:` 是给快捷键设置页和 `helpText(title:)` 用的英文。

例：`New Worktree`、`Open Settings`、`Toggle Agent Island`、`Select Book 1`…`9`、`Select Worktree 1`…`9`、`Find` / `Find Next`。

`CommandID` 字符串值（`newWorktree` 等）**不译**。  
显示层：`String(localized: String.LocalizationValue(title))` 或独立 localized 字段。

---

## P0 — 设置枚举（Picker 选项）

`Text(mode.title)` 吃的是 `String`，catalog 没有这些 key。

| 类型 | 文件 | 英文值 |
|---|---|---|
| `AppearanceMode` | `AppearanceMode.swift` | System / Light / Dark |
| `WindowTintMode` | `WindowTintMode.swift` | None / Repository Color / Custom Color |
| `ShelfSpineTintFallback` | `ShelfSpineTintFallback.swift` | Neutral / System Tint |
| `DefaultViewMode` | `DefaultViewMode.swift` | Normal View / Shelf View / Canvas View |
| `CanvasDefaultLayout` | `CanvasDefaultLayout.swift` | Uniform / Tile + 两段说明 |
| `DockBounceMode` | `DockBounceMode.swift` | Off / Once / Continuously |
| `PullRequestMergeStrategy` | `PullRequestMergeStrategy.swift` | Merge / Squash / Rebase |
| `MergedWorktreeAction` | `MergedWorktreeAction.swift` | Archive / Delete |
| `AutoDeletePeriod` | `AutoDeletePeriod.swift` | After 1 day … After 30 days；DEBUG Immediately |
| `NotificationSound` | `NotificationSound.swift` | Never / Prowl Classic；系统音名不译 |
| `UserCustomCommandExecution` | `UserRepositorySettings.swift` | New Tab / In Place / New Split；Right/Left/Down/Up |
| `AppLanguage.title` | `AppLanguage.swift` | 已是各语言本名，**不必再译** |
| `OpenWorktreeAction` | `Domain/OpenWorktreeAction.swift` | Open Finder 等 |
| `ExternalDiffTool` | `Domain/ExternalDiffTool.swift` | Built-in / Hunk / 工具名 |
| `RepositoryColorChoice` | `Domain/RepositoryColorChoice.swift` | Red / Orange / … |
| `AgentRuntimeExecutionMode` | `AgentRuntimeAdapter.swift` | Standard / Unrestricted |
| `AgentDisplayState` | `ActiveAgentRow.swift` | Working / Blocked / Done（产品状态名可保留英文） |
| `GitClient` 分支源 | `GitClientTypes.swift` | Local Branches 等 |

`AppearanceSettingsView` 的 `tintFootnote` / `shelfSpineTintFootnote` 是计算 `String`，同样要 `String(localized:)`。

---

## P1 — 窗口标题 / 菜单 help

`App/WindowTitle.swift`

- `appName = "Prowl"` → 产品名，**保留**
- `archivedWorktreesTitle = "Archived Worktrees"` → localize
- `canvasTitle = "Canvas"` → 可保留 Canvas 或译「画布」；与设置枚举一致
- `case nil` DEBUG 探针 → 删

`Commands/*.swift` 里 `Button("…")` 字面量已提取；`.help(helpText(title: "…"))` 的 title 是 `String`，**未提取**。与 AppShortcuts 同一批显示名，改一处即可。

---

## P1 — Ask Agent Help

`Features/Help/AskAgentHelpPrompt.swift` 已按语言手写四套字符串（en / 简中 / 繁中 / 日）。

计划合同：

- **chrome**（title / explanation / 按钮）：本次启动应用语言
- **prompt**（显示和复制）：系统首选语言，不受 Prowl `AppleLanguages` 污染

现状：`strings(locale:)` 默认 `Locale.current`，启动桥接之后会被应用语言带跑。需要拆 chrome vs prompt 的 locale 输入，并改调用方。这是结构活，不是漏译。

---

## 跳过（不要译）

| 类别 | 依据 |
|---|---|
| `ProwlCLI/`、`CLIService/Shared/` help / error / summary | 计划：CLI 保持英文 |
| Ghostty `action` / 原始 `title` 用作命令 ID | 译了会打坏 palette / keybind 身份 |
| 用户仓库名、工作树名、自定义命令标题、Profile 名 | 用户数据 |
| `error.message` 来自 git/gh/系统 | 不要按英文文本分支翻译 |
| Sparkle 标准 UI、Ghostty 内部 UI | 第三方 |
| `PROWL_*` 环境变量名、JSON 键、CommandID raw value | 协议 |
| 产品名 Prowl；工具名 Ghostty / Claude / Codex / GitHub | 术语表 |
| DEBUG G1a 探针 | 删除，不翻译进正式表 |

---

## 建议实施顺序

1. 删 G1a DEBUG 探针（设置 Section、WindowTitle、NSMenu 探针、Clone `panel.message`）。
2. AppKit：右键菜单、Updater NSAlert、关闭确认、改标题、三个 NSOpenPanel。
3. `TextState` + toast：先退出确认 / Run Script 相关 / Updater（计划验收矩阵）。
4. 设置枚举 `title`/`label` + footnotes。
5. AppShortcuts 显示名 + 命令面板 title + 中文 keywords。
6. Ask Agent Help chrome/prompt 拆 locale。
7. 再 `make build-app` 合并新 `.stringsdata`，只译新增 key。
8. Task 5 实机矩阵 + `docs/components/settings.md` / `settings-fields.md` / `CHANGELOG.md`。

每批改完应用语言冷启动抽查对应表面，避免只信 catalog 行数。
